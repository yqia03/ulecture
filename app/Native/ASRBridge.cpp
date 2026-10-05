#include "ASRBridge.h"
#include "whisper.h"
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>
struct Segment { std::string text; double start; double end; };
struct Engine { whisper_context *ctx=nullptr; whisper_vad_context *vad=nullptr; std::vector<Segment> results; };
static void quiet_log(enum ggml_log_level, const char *, void *) {}
void *classroom_asr_open(const char *model_path, const char *vad_path) {
    whisper_log_set(quiet_log, nullptr);
    auto *e=new Engine;
    auto p=whisper_context_default_params(); p.use_gpu=true; p.flash_attn=true;
    e->ctx=whisper_init_from_file_with_params(model_path,p);
    if(!e->ctx) {delete e;return nullptr;}
    auto vp=whisper_vad_default_context_params(); vp.n_threads=2; vp.use_gpu=false;
    e->vad=whisper_vad_init_from_file_with_params(vad_path,vp);
    if(!e->vad) {whisper_free(e->ctx);delete e;return nullptr;}
    return e;
}
void classroom_asr_close(void *ptr) {if(!ptr)return;auto *e=(Engine*)ptr;whisper_free(e->ctx);whisper_vad_free(e->vad);delete e;}
int classroom_asr_run(void *ptr,const float *samples,int count,const char *language) {
    auto *e=(Engine*)ptr;if(!e || !samples || count<1 || count>480000)return -1;
    e->results.clear();
    double energy=0;for(int i=0;i<count;i++){if(!std::isfinite(samples[i]))return -2;energy+=samples[i]*samples[i];}
    if(std::sqrt(energy/count)<0.0002)return 0;
    auto vp=whisper_vad_default_params(); vp.threshold=0.5; vp.min_speech_duration_ms=150; vp.min_silence_duration_ms=500;
    auto *speech=whisper_vad_segments_from_samples(e->vad,vp,samples,count);
    if(!speech)return -3;
    bool detected=whisper_vad_segments_n_segments(speech)>0;whisper_vad_free_segments(speech);
    if(!detected)return 0;
    auto p=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads=4;p.translate=false;p.no_context=true;p.language=language;p.detect_language=false;
    p.print_realtime=false;p.print_progress=false;p.print_timestamps=false;p.print_special=false;
    p.suppress_blank=true;p.suppress_nst=true;p.temperature=0;p.temperature_inc=0;p.no_speech_thold=0.6;
    // No reference text, hints or previous hypotheses are fed to the decoder.
    int code=whisper_full(e->ctx,p,samples,count);if(code!=0)return code;
    double duration=double(count)/16000;
    for(int i=0;i<whisper_full_n_segments(e->ctx);i++){
        if(whisper_full_get_segment_no_speech_prob(e->ctx,i)>0.85)continue;
        const char *t=whisper_full_get_segment_text(e->ctx,i);if(!t || !*t)continue;
        double a=std::clamp(double(whisper_full_get_segment_t0(e->ctx,i))/100,0.0,duration);
        double b=std::clamp(double(whisper_full_get_segment_t1(e->ctx,i))/100,a,duration);
        if(b>a)e->results.push_back({t,a,b});
    }return 0;
}
int classroom_asr_count(void *e){return e?int(((Engine*)e)->results.size()):0;}
const char *classroom_asr_text(void *e,int i){return ((Engine*)e)->results.at(i).text.c_str();}
double classroom_asr_start(void *e,int i){return ((Engine*)e)->results.at(i).start;}
double classroom_asr_end(void *e,int i){return ((Engine*)e)->results.at(i).end;}

void *classroom_vad_open(const char *path) {
    auto params=whisper_vad_default_context_params();params.use_gpu=false;params.n_threads=1;
    return whisper_vad_init_from_file_with_params(path,params);
}
void classroom_vad_close(void *vad){if(vad)whisper_vad_free((whisper_vad_context*)vad);}
float classroom_vad_probability(void *vad,const float *samples,int count){
    if(!vad || !samples || count<1 || count>16000)return -1;
    auto *ctx=(whisper_vad_context*)vad;
    if(!whisper_vad_detect_speech_no_reset(ctx,samples,count))return -1;
    int n=whisper_vad_n_probs(ctx);float *probs=whisper_vad_probs(ctx), result=0;
    for(int i=0;i<n;i++)result=std::max(result,probs[i]);return result;
}
