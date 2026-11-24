/* The libretro log callback (retro_log_printf_t) is variadic. Zig 0.17.1
 * cannot define C variadic functions on every target, so this shim formats the
 * message with stb_sprintf (no libc needed) and hands the text to Zig
 * (core_log.zig). */

#define STB_SPRINTF_IMPLEMENTATION
#define STB_SPRINTF_STATIC
/* Debug builds compile C with UBSan; stb's unaligned fast paths would trap. */
#define STB_SPRINTF_NOUNALIGNED
#include "stb_sprintf.h"

#define TEMUI_CORE_LOG_MAX 1024

/* Defined in core_log.zig. `level` is a retro_log_level value. */
extern void temui_core_log_sink(int level, const char *msg, size_t len);

/* Matches retro_log_printf_t: void (*)(enum retro_log_level, const char *, ...).
 * The enum is passed as int, which is its C representation. */
void temui_core_log(int level, const char *fmt, ...)
{
   static const char ellipsis[] = "\xe2\x80\xa6"; /* U+2026, 3 bytes */
   char buf[TEMUI_CORE_LOG_MAX];
   size_t len;
   int n;
   va_list ap;

   if (!fmt)
      fmt = "(null format)";
   va_start(ap, fmt);
   n = stbsp_vsnprintf(buf, (int)sizeof buf, fmt, ap);
   va_end(ap);

   if (n < 0)
      n = 0;
   if ((size_t)n >= sizeof buf) {
      /* Truncated: end the visible text with an ellipsis. */
      len = sizeof buf - 1;
      buf[len - 3] = ellipsis[0];
      buf[len - 2] = ellipsis[1];
      buf[len - 1] = ellipsis[2];
   } else {
      len = (size_t)n;
      /* Cores end most messages with a newline; the file log adds its own. */
      if (len > 0 && buf[len - 1] == '\n')
         len--;
      if (len > 0 && buf[len - 1] == '\r')
         len--;
   }
   temui_core_log_sink(level, buf, len);
}
