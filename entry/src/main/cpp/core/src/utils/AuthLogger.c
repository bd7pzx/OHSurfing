#include "utils/Logger.h"
#include <stdarg.h>

/* The UI owns a small, curated log. Protocol payloads can contain credentials. */
void log_out(LogLevel level, const char* file, uint32_t line, const char* fmt, ...)
{
    (void)level; (void)file; (void)line; (void)fmt;
}
