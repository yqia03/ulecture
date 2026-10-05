#ifndef CLASSROOM_ASR_BRIDGE_H
#define CLASSROOM_ASR_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *classroom_vad_open(const char *path);
void classroom_vad_close(void *vad);
float classroom_vad_probability(void *vad, const float *samples, int count);
void *classroom_asr_open(const char *model_path, const char *vad_path);
void classroom_asr_close(void *engine);
int classroom_asr_run(void *engine, const float *samples, int count, const char *language);
int classroom_asr_count(void *engine);
const char *classroom_asr_text(void *engine, int index);
double classroom_asr_start(void *engine, int index);
double classroom_asr_end(void *engine, int index);
#ifdef __cplusplus
}
#endif
#endif
