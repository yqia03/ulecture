// Diagnostic ASR pass over 16 kHz mono float32 PCM, never a reference prompt.
#include "ASRBridge.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <vector>
#include <cstring>
int main(int argc, char** argv) {
    if(argc < 5) return 2;
    void* engine = classroom_asr_open(argv[1], argv[2]);
    if(!engine) return 3;
    int result = 0;
    for(int arg = 4; arg < argc; ++arg) {
        std::ifstream in(argv[arg], std::ios::binary);
        std::vector<char> data((std::istreambuf_iterator<char>(in)), {});
        if(data.empty() || data.size() % sizeof(float)) { result=4; break; }
        std::vector<float> pcm(data.size()/sizeof(float));
        std::memcpy(pcm.data(), data.data(), data.size());
        if(classroom_asr_run(engine, pcm.data(), (int)pcm.size(), argv[3])) { result=5; break; }
        std::cout << arg-4 << "\t";
        for(int i=0; i<classroom_asr_count(engine); ++i) std::cout << classroom_asr_text(engine,i);
        std::cout << std::endl;
    }
    classroom_asr_close(engine);
    return result;
}
