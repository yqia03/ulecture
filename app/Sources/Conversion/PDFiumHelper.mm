#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "fpdfview.h"
#include "fpdf_edit.h"
#include "fpdf_text.h"
#include "fpdf_save.h"
#include "fpdf_transformpage.h"
#include "fpdf_ppo.h"
#include <sys/resource.h>
#include <cmath>
#include <vector>

// Standalone process: no V8/XFA, no provider transport, no user profile. All
// object edits target a disposable source snapshot and save a separate PDF.
struct Writer { FPDF_FILEWRITE api; FILE* file; };
static int writeBlock(FPDF_FILEWRITE* api, const void* data, unsigned long length) {
    return fwrite(data, 1, length, reinterpret_cast<Writer*>(api)->file) == length;
}
static void saveDocument(FPDF_DOCUMENT document, NSString* path) {
    FILE* file = fopen(path.fileSystemRepresentation, "wb");
    if (!file) @throw [NSException exceptionWithName:@"writeFailed" reason:nil userInfo:nil];
    Writer writer = {{1, writeBlock}, file}; BOOL success = FPDF_SaveAsCopy(document, &writer.api, FPDF_NO_INCREMENTAL); int closed = fclose(file);
    if (!success || closed) @throw [NSException exceptionWithName:@"saveFailed" reason:nil userInfo:nil];
}
static BOOL renderBackground(FPDF_PAGE page, NSString* path) {
    // Nested Form mutation is correct in the live object tree but some PDFium
    // versions do not serialize every ancestor stream. A high-resolution
    // background for those pages preserves clipping, transparency and figures.
    double scale = 300.0 / 72.0;
    int width = (int)ceil(FPDF_GetPageWidthF(page) * scale), height = (int)ceil(FPDF_GetPageHeightF(page) * scale);
    if (width <= 0 || height <= 0 || (int64_t)width * height > 80000000) return NO;
    FPDF_BITMAP bitmap = FPDFBitmap_Create(width, height, 1);
    if (!bitmap) return NO;
    FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
    CFDataRef bytes = CFDataCreate(kCFAllocatorDefault, (UInt8*)FPDFBitmap_GetBuffer(bitmap), (CFIndex)FPDFBitmap_GetStride(bitmap) * height);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(bytes); CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, FPDFBitmap_GetStride(bitmap), color, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, nullptr, false, kCGRenderingIntentDefault);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
    BOOL success = NO;
    if (destination && image) { CGImageDestinationAddImage(destination, image, nullptr); success = CGImageDestinationFinalize(destination); }
    if (destination) CFRelease(destination); if (image) CGImageRelease(image); CGColorSpaceRelease(color); CGDataProviderRelease(provider); CFRelease(bytes); FPDFBitmap_Destroy(bitmap); return success;
}
static NSData* visualFingerprint(FPDF_PAGE page) {
    const int width = 128, height = 128;
    FPDF_BITMAP bitmap = FPDFBitmap_Create(width, height, 1);
    if (!bitmap) return nil;
    FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
    NSData* bytes = [NSData dataWithBytes:FPDFBitmap_GetBuffer(bitmap) length:FPDFBitmap_GetStride(bitmap)*height];
    FPDFBitmap_Destroy(bitmap); return bytes;
}
static BOOL visiblyChanged(NSData* before, NSData* after) {
    if (!before || before.length != after.length) return YES;
    const UInt8* a = (const UInt8*)before.bytes; const UInt8* b = (const UInt8*)after.bytes;
    size_t different = 0;
    for (size_t i = 0; i + 3 < before.length; i += 4) if (abs(a[i]-b[i]) > 12 || abs(a[i+1]-b[i+1]) > 12 || abs(a[i+2]-b[i+2]) > 12) ++different;
    return different > before.length / 4 / 100;
}
static NSString* objectText(FPDF_PAGEOBJECT object, FPDF_TEXTPAGE textPage) {
    auto size = FPDFTextObj_GetText(object, textPage, nullptr, 0);
    if (size < 2 || size > 2000000) return @"";
    std::vector<unsigned short> buffer((size + 1) / 2);
    if (FPDFTextObj_GetText(object, textPage, buffer.data(), size) != size) return @"";
    return [[NSString alloc] initWithBytes:buffer.data() length:size - 2 encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
}
static void visit(FPDF_PAGE page, FPDF_PAGEOBJECT form, NSString* prefix, FPDF_TEXTPAGE textPage,
                  NSDictionary* characterBounds, NSMutableArray* objects, NSSet* removals,
                  NSMutableSet* removed, int depth) {
    if (depth > 32) @throw [NSException exceptionWithName:@"depthLimit" reason:nil userInfo:nil];
    int count = form ? FPDFFormObj_CountObjects(form) : FPDFPage_CountObjects(page);
    for (int i = count - 1; i >= 0; --i) {
        FPDF_PAGEOBJECT object = form ? FPDFFormObj_GetObject(form, i) : FPDFPage_GetObject(page, i);
        if (!object) continue;
        NSString* identifier = [prefix stringByAppendingFormat:@".%d", i];
        int type = FPDFPageObj_GetType(object);
        if (type == FPDF_PAGEOBJ_FORM) {
            NSUInteger before = removed.count;
            visit(page, object, identifier, textPage, characterBounds, objects, removals, removed, depth + 1);
            // Removal dirties the immediate Form. Every ancestor must also be
            // dirty or GenerateContent can retain an older nested stream.
            if (removed.count != before) {
                FS_MATRIX matrix;
                if (!FPDFPageObj_GetMatrix(object, &matrix) || !FPDFPageObj_SetMatrix(object, &matrix)) @throw [NSException exceptionWithName:@"formMatrix" reason:nil userInfo:nil];
            }
        }
        if (type != FPDF_PAGEOBJ_TEXT) continue;
        if (removals) {
            if ([removals containsObject:identifier]) {
                bool success = form ? FPDFFormObj_RemoveObject(form, object) : FPDFPage_RemoveObject(page, object);
                if (!success) @throw [NSException exceptionWithName:@"removeFailed" reason:nil userInfo:nil];
                [removed addObject:identifier]; FPDFPageObj_Destroy(object);
            }
            continue;
        }
        NSString* text = objectText(object, textPage);
        NSArray* bounds = characterBounds[[NSValue valueWithPointer:object]];
        // Character bounds are in page coordinates, including every parent
        // Form transform. Missing geometry is reported, never guessed.
        if (!bounds || ![[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) continue;
        float fontSize = 0; FPDFTextObj_GetFontSize(object, &fontSize);
        unsigned int r = 0, g = 0, b = 0, a = 255; FPDFPageObj_GetFillColor(object, &r, &g, &b, &a);
        char fontName[256] = {0}; FPDFFont_GetBaseFontName(FPDFTextObj_GetFont(object), fontName, sizeof(fontName));
        [objects addObject:@{@"id":identifier, @"text":text, @"bounds":[bounds subarrayWithRange:NSMakeRange(0,4)], @"fontSize":@(fontSize),
                            @"rgba":@[@(r),@(g),@(b),@(a)], @"angle":bounds[4], @"fontName":@((const char*)fontName)}];
    }
}
int main(int argc, char** argv) {
    @autoreleasepool {
        struct rlimit cpu = {90, 95}, file = {512 * 1024 * 1024, 512 * 1024 * 1024}, descriptors = {128, 128};
        setrlimit(RLIMIT_CPU, &cpu); setrlimit(RLIMIT_FSIZE, &file); setrlimit(RLIMIT_NOFILE, &descriptors);
        if (argc < 4) return 64;
        NSString* operation = @(argv[1]); NSString* input = @(argv[2]); NSString* output = @(argv[3]);
        if ([input.stringByStandardizingPath isEqual:output.stringByStandardizingPath]) return 64;
        NSData* data = [NSData dataWithContentsOfFile:input];
        if (!data || data.length > 200 * 1024 * 1024) return 65;
        FPDF_InitLibrary(); FPDF_DOCUMENT document = FPDF_LoadMemDocument64(data.bytes, data.length, nullptr);
        if (!document) { fprintf(stderr, "pdfLoad:%lu\n", FPDF_GetLastError()); FPDF_DestroyLibrary(); return 65; }
        int result = 0;
        @try {
            if ([operation isEqual:@"compose"] && argc == 6) {
                FPDF_DOCUMENT translated = FPDF_LoadDocument(argv[4], nullptr);
                NSData* mappings = [NSData dataWithContentsOfFile:@(argv[5])];
                NSDictionary* originalPages = mappings ? [NSJSONSerialization JSONObjectWithData:mappings options:0 error:nil] : nil;
                if (!translated || ![originalPages isKindOfClass:NSDictionary.class]) @throw [NSException exceptionWithName:@"invalidComposition" reason:nil userInfo:nil];
                FPDF_DOCUMENT composed = FPDF_CreateNewDocument(); int count = FPDF_GetPageCount(translated);
                if (!composed || count <= 0 || count > 4000) @throw [NSException exceptionWithName:@"pageLimit" reason:nil userInfo:nil];
                for (int p = 0; p < count; ++p) {
                    NSNumber* sourcePage = originalPages[[@(p) stringValue]];
                    int sourceIndex = sourcePage ? sourcePage.intValue : p;
                    if (!FPDF_ImportPagesByIndex(composed, sourcePage ? document : translated, &sourceIndex, 1, p)) @throw [NSException exceptionWithName:@"pageImportFailed" reason:nil userInfo:nil];
                }
                saveDocument(composed, output); FPDF_CloseDocument(composed); FPDF_CloseDocument(translated);
            } else if ([operation isEqual:@"normalize"]) {
                int count = FPDF_GetPageCount(document);
                if (count <= 0 || count > 400) @throw [NSException exceptionWithName:@"pageLimit" reason:nil userInfo:nil];
                for (int p = 0; p < count; ++p) {
                    FPDF_PAGE page = FPDF_LoadPage(document, p); FS_RECTF box;
                    if (!page || !FPDF_GetPageBoundingBox(page, &box)) @throw [NSException exceptionWithName:@"invalidBox" reason:nil userInfo:nil];
                    float w = box.right-box.left, h = box.top-box.bottom;
                    if (!(w > 0 && h > 0 && w <= 4000 && h <= 4000)) @throw [NSException exceptionWithName:@"pageLimit" reason:nil userInfo:nil];
                    int rotation = FPDFPage_GetRotation(page); FS_MATRIX matrix = {1,0,0,1,-box.left,-box.bottom};
                    if (rotation == 1) matrix = {0,-1,1,0,-box.bottom,box.right};
                    if (rotation == 2) matrix = {-1,0,0,-1,box.right,box.top};
                    if (rotation == 3) matrix = {0,1,-1,0,box.top,-box.left};
                    float width = rotation % 2 ? h : w, height = rotation % 2 ? w : h;
                    FS_RECTF clip = {0,height,width,0};
                    if (!FPDFPage_TransFormWithClip(page, &matrix, &clip)) @throw [NSException exceptionWithName:@"transformFailed" reason:nil userInfo:nil];
                    FPDFPage_SetRotation(page, 0); FPDFPage_SetMediaBox(page, 0,0,width,height); FPDFPage_SetCropBox(page, 0,0,width,height);
                    FPDF_ClosePage(page);
                }
                // Preserve original font programs and ToUnicode maps while
                // applying crop/rotation through a page-stream transform.
                saveDocument(document, output);
            } else {
            BOOL extract = [operation isEqual:@"extract"];
            if (!extract && (![operation isEqual:@"strip"] || argc != 5)) @throw [NSException exceptionWithName:@"invalidCommand" reason:nil userInfo:nil];
            NSSet* removals = nil;
            if (!extract) {
                NSData* idsData = [NSData dataWithContentsOfFile:@(argv[4])];
                id ids = idsData ? [NSJSONSerialization JSONObjectWithData:idsData options:0 error:nil] : nil;
                if (![ids isKindOfClass:NSArray.class] || [ids count] > 1000000) @throw [NSException exceptionWithName:@"invalidIDs" reason:nil userInfo:nil];
                for (id identifier in ids) if (![identifier isKindOfClass:NSString.class]) @throw [NSException exceptionWithName:@"invalidID" reason:nil userInfo:nil];
                removals = [NSSet setWithArray:ids];
            }
            NSMutableSet* removed = NSMutableSet.set; NSMutableArray* pages = NSMutableArray.array; NSMutableArray* rasterPages = NSMutableArray.array;
            NSMutableDictionary* fingerprints = NSMutableDictionary.dictionary; NSMutableDictionary* rasterReasons = NSMutableDictionary.dictionary;
            int pageCount = FPDF_GetPageCount(document);
            if (pageCount <= 0 || pageCount > 400) @throw [NSException exceptionWithName:@"pageLimit" reason:nil userInfo:nil];
            for (int p = 0; p < pageCount; ++p) {
                FPDF_PAGE page = FPDF_LoadPage(document, p);
                if (!page) @throw [NSException exceptionWithName:@"pageLoad" reason:nil userInfo:nil];
                FPDF_TEXTPAGE textPage = extract ? FPDFText_LoadPage(page) : nullptr;
                NSMutableDictionary* bounds = NSMutableDictionary.dictionary;
                if (textPage) {
                    int chars = FPDFText_CountChars(textPage);
                    if (chars > 1000000) @throw [NSException exceptionWithName:@"textLimit" reason:nil userInfo:nil];
                    for (int c = 0; c < chars; ++c) {
                        FPDF_PAGEOBJECT object = FPDFText_GetTextObject(textPage, c);
                        double left, right, bottom, top;
                        if (!object || !FPDFText_GetCharBox(textPage, c, &left, &right, &bottom, &top) || !std::isfinite(left+right+bottom+top)) continue;
                        NSValue* key = [NSValue valueWithPointer:object]; NSArray* prior = bounds[key];
                        if (prior) { left = fmin(left, [prior[0] doubleValue]); bottom = fmin(bottom, [prior[1] doubleValue]); right = fmax(right, [prior[2] doubleValue]); top = fmax(top, [prior[3] doubleValue]); }
                        // Character angle includes page and every enclosing
                        // Form transform. Object matrices alone are local.
                        double clockwise = FPDFText_GetCharAngle(textPage, c);
                        double angle = atan2(sin(-clockwise), cos(-clockwise));
                        bounds[key] = @[@(left),@(bottom),@(right),@(top),@(angle)];
                    }
                }
                NSMutableArray* objects = NSMutableArray.array;
                visit(page, nullptr, [NSString stringWithFormat:@"p%d", p+1], textPage, bounds, objects, removals, removed, 0);
                if (extract) [pages addObject:@{@"number":@(p+1), @"width":@(FPDF_GetPageWidthF(page)), @"height":@(FPDF_GetPageHeightF(page)), @"rotation":@(FPDFPage_GetRotation(page)), @"objects":objects}];
                else {
                    NSString* prefix = [NSString stringWithFormat:@"p%d.", p+1]; BOOL nested = NO, changed = NO;
                    for (NSString* identifier in removed) if ([identifier hasPrefix:prefix]) { changed = YES; if ([identifier componentsSeparatedByString:@"."].count > 2) nested = YES; }
                    if (changed) {
                        NSString* imagePath = [output stringByAppendingFormat:@".page%d.png", p+1];
                        if (!renderBackground(page, imagePath)) @throw [NSException exceptionWithName:@"renderFailed" reason:nil userInfo:nil];
                        NSData* fingerprint = visualFingerprint(page); if (!fingerprint) @throw [NSException exceptionWithName:@"renderFailed" reason:nil userInfo:nil];
                        fingerprints[@(p+1)] = fingerprint;
                        if (nested) { [rasterPages addObject:@(p+1)]; rasterReasons[[@(p+1) stringValue]] = @"nestedFormSerialization"; }
                    }
                    if (changed && !FPDFPage_GenerateContent(page)) @throw [NSException exceptionWithName:@"generateFailed" reason:nil userInfo:nil];
                }
                if (textPage) FPDFText_ClosePage(textPage); FPDF_ClosePage(page);
            }
            if (extract) {
                NSData* json = [NSJSONSerialization dataWithJSONObject:@{@"schema":@1,@"engine":@"pdfium-153.0.7999.0",@"pages":pages} options:NSJSONWritingSortedKeys error:nil];
                NSError* error = nil;
                if (!json || ![json writeToFile:output options:0 error:&error]) { fprintf(stderr, "writeCode:%ld errno:%d\n", (long)error.code, errno); @throw [NSException exceptionWithName:@"writeFailed" reason:nil userInfo:nil]; }
            } else {
                if (![removed isEqualToSet:removals]) @throw [NSException exceptionWithName:@"unmatchedIDs" reason:nil userInfo:nil];
                saveDocument(document, output);
                // Editing must not silently change color spaces, clipping or
                // transparency while serializing. Compare saved graphics with
                // the live, text-removed tree before accepting vector output.
                FPDF_DOCUMENT saved = FPDF_LoadDocument(output.fileSystemRepresentation, nullptr);
                if (!saved) @throw [NSException exceptionWithName:@"verifySaveFailed" reason:nil userInfo:nil];
                for (NSNumber* number in fingerprints) {
                    FPDF_PAGE page = FPDF_LoadPage(saved, number.intValue - 1);
                    if (!page) { FPDF_CloseDocument(saved); @throw [NSException exceptionWithName:@"verifyPageFailed" reason:nil userInfo:nil]; }
                    if (visiblyChanged(fingerprints[number], visualFingerprint(page)) && ![rasterPages containsObject:number]) { [rasterPages addObject:number]; rasterReasons[number.stringValue] = @"graphicsSerializationChanged"; }
                    FPDF_ClosePage(page);
                    if (![rasterPages containsObject:number]) [[NSFileManager defaultManager] removeItemAtPath:[output stringByAppendingFormat:@".page%d.png", number.intValue] error:nil];
                }
                FPDF_CloseDocument(saved);
                [rasterPages sortUsingSelector:@selector(compare:)];
                NSData* manifest = [NSJSONSerialization dataWithJSONObject:@{@"rasterPages":rasterPages, @"dpi":@300, @"reasons":rasterReasons} options:NSJSONWritingSortedKeys error:nil];
                if (![manifest writeToFile:[output stringByAppendingString:@".coverage.json"] options:0 error:nil]) @throw [NSException exceptionWithName:@"coverageWriteFailed" reason:nil userInfo:nil];
            }
            }
        } @catch (NSException* exception) { fprintf(stderr, "%s\n", exception.name.UTF8String); result = 65; }
        FPDF_CloseDocument(document); FPDF_DestroyLibrary(); return result;
    }
}
