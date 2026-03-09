#ifndef ZWGSL_H
#define ZWGSL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ZWGSL_TARGET_GLSL_ES_300 = 0,
    ZWGSL_TARGET_WGSL = 1,
} ZwgslTarget;

typedef enum {
    ZWGSL_OK = 0,
    ZWGSL_ERROR_SYNTAX = 1,
    ZWGSL_ERROR_TYPE = 2,
    ZWGSL_ERROR_SEMANTIC = 3,
    ZWGSL_ERROR_INTERNAL = 99,
} ZwgslErrorKind;

typedef struct {
    ZwgslErrorKind kind;
    const char* message;
    uint32_t line;
    uint32_t column;
} ZwgslError;

typedef struct {
    const char* vertex_source;
    const char* fragment_source;
    const char* compute_source;
    const ZwgslError* errors;
    uint32_t error_count;
    void* _internal;
} ZwgslResult;

typedef struct {
    ZwgslTarget target;
    int emit_debug_comments;
    int optimize_output;
} ZwgslOptions;

ZwgslResult zwgsl_compile(const char* source, size_t source_len, ZwgslOptions options);
void zwgsl_free(ZwgslResult* result);
const char* zwgsl_version(void);

#ifdef __cplusplus
}
#endif

#endif
