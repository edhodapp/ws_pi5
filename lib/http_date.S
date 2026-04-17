/*
 * http_date.S — HTTP-date formatter (RFC 5322 / RFC 9110 §5.6.7)
 *
 * Converts Unix timestamp to:
 *   "Wed, 16 Apr 2026 19:45:00 GMT"  (29 bytes, no NUL)
 *
 * Gregorian calendar: leap year when y%4==0 && (y%100!=0 || y%400==0)
 */

.include "http.inc"

.global http_format_date

.section .text

/*
 * http_format_date — Format Unix timestamp as HTTP-date
 *
 * x0: Unix timestamp (seconds since 1970-01-01 00:00:00 UTC)
 * x1: output buffer (must hold >= 29 bytes)
 *
 * Returns: w0 = 29 (bytes written)
 * Clobbers: x0-x7, x19-x24 saved/restored
 */
http_format_date:
    stp     x29, x30, [sp, #-64]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                 /* x19 = timestamp */
    mov     x20, x1                 /* x20 = output buf */

    /* --- Decompose timestamp into date/time components --- */

    /* seconds_in_day = timestamp % 86400 */
    ldr     x1, =86400
    udiv    x2, x19, x1            /* x2 = days since epoch */
    msub    x3, x2, x1, x19        /* x3 = seconds_in_day */

    mov     w21, w2                 /* w21 = total_days */

    /* hour = seconds_in_day / 3600 */
    mov     w4, #3600
    udiv    w22, w3, w4             /* w22 = hour */
    msub    w3, w22, w4, w3         /* w3 = remaining seconds */

    /* minute = remaining / 60 */
    mov     w4, #60
    udiv    w23, w3, w4             /* w23 = minute */
    msub    w24, w23, w4, w3        /* w24 = second */

    /* Day of week: (total_days + 4) % 7  (epoch=Thursday=4) */
    add     w0, w21, #4
    mov     w1, #7
    udiv    w2, w0, w1
    msub    w0, w2, w1, w0          /* w0 = dow (0=Sun..6=Sat) */

    /* Write day-of-week name (3 chars) */
    ldr     x1, =http_dow_names
    add     x1, x1, x0, lsl #2     /* 4 bytes per entry (3 chars + pad) */
    ldrb    w2, [x1]
    strb    w2, [x20]
    ldrb    w2, [x1, #1]
    strb    w2, [x20, #1]
    ldrb    w2, [x1, #2]
    strb    w2, [x20, #2]

    /* ", " */
    mov     w2, #','
    strb    w2, [x20, #3]
    mov     w2, #' '
    strb    w2, [x20, #4]

    /* --- Compute year/month/day from total_days --- */
    /* Civil calendar from days since epoch.
     * Algorithm: start from 1970, subtract years until days < 365/366. */
    mov     w5, #1970               /* year */
    mov     w6, w21                 /* remaining days */

.Ldate_year_loop:
    /* Is this year a leap year? */
    bl      http_is_leap_year       /* w0=w5 → w0=1 if leap */
    add     w1, w0, #365            /* days_in_year = 365 + leap */
    cmp     w6, w1
    b.lo    .Ldate_year_found
    sub     w6, w6, w1
    add     w5, w5, #1
    b       .Ldate_year_loop

.Ldate_year_found:
    /* w5 = year, w6 = day_of_year (0-based), w0 = is_leap */
    mov     w7, w0                  /* w7 = is_leap for this year */

    /* Find month: subtract month lengths */
    ldr     x1, =http_month_days
    mov     w3, #0                  /* month index (0=Jan) */

.Ldate_month_loop:
    ldrb    w4, [x1, x3]           /* days in this month */
    /* February: add 1 if leap year */
    cmp     w3, #1                  /* month 1 = February */
    b.ne    .Ldate_not_feb
    add     w4, w4, w7             /* +1 if leap */
.Ldate_not_feb:
    cmp     w6, w4
    b.lo    .Ldate_month_found
    sub     w6, w6, w4
    add     w3, w3, #1
    b       .Ldate_month_loop

.Ldate_month_found:
    /* w3 = month (0-based), w6 = day (0-based) */
    add     w6, w6, #1             /* day is 1-based */
    mov     w7, w3                 /* save month across bl calls */

    /* Write day (2 digits) at offset 5 */
    mov     w0, w6
    add     x1, x20, #5
    bl      http_write_2digits     /* clobbers w0, w2-w3 */

    /* " " */
    mov     w2, #' '
    strb    w2, [x20, #7]

    /* Write month name (3 chars) at offset 8 */
    ldr     x1, =http_month_names
    add     x1, x1, x7, lsl #2    /* 4 bytes per entry, w7=month */
    ldrb    w2, [x1]
    strb    w2, [x20, #8]
    ldrb    w2, [x1, #1]
    strb    w2, [x20, #9]
    ldrb    w2, [x1, #2]
    strb    w2, [x20, #10]

    /* " " */
    mov     w2, #' '
    strb    w2, [x20, #11]

    /* Write year (4 digits) at offset 12 */
    mov     w0, w5
    add     x1, x20, #12
    bl      http_write_4digits

    /* " " */
    mov     w2, #' '
    strb    w2, [x20, #16]

    /* Write hour:minute:second at offset 17 */
    mov     w0, w22
    add     x1, x20, #17
    bl      http_write_2digits

    mov     w2, #':'
    strb    w2, [x20, #19]

    mov     w0, w23
    add     x1, x20, #20
    bl      http_write_2digits

    mov     w2, #':'
    strb    w2, [x20, #22]

    mov     w0, w24
    add     x1, x20, #23
    bl      http_write_2digits

    /* " GMT" */
    mov     w2, #' '
    strb    w2, [x20, #25]
    mov     w2, #'G'
    strb    w2, [x20, #26]
    mov     w2, #'M'
    strb    w2, [x20, #27]
    mov     w2, #'T'
    strb    w2, [x20, #28]

    mov     w0, #29

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret

/*
 * http_is_leap_year — Check if year is a Gregorian leap year
 *
 * w5: year (preserved, checked but not modified)
 * Returns: w0 = 1 if leap, 0 if not
 * Clobbers: w0-w2
 */
.global http_is_leap_year
http_is_leap_year:
    /* y%4 != 0 → not leap */
    tst     w5, #3                 /* y & 3 == y % 4 for positive y */
    b.ne    .Lnot_leap

    /* y%100 == 0 → check y%400 */
    mov     w1, #100
    udiv    w2, w5, w1
    msub    w0, w2, w1, w5         /* w0 = y % 100 */
    cbnz    w0, .Lis_leap          /* y%4==0 && y%100!=0 → leap */

    /* y%400 == 0 → leap; else not */
    mov     w1, #400
    udiv    w2, w5, w1
    msub    w0, w2, w1, w5         /* w0 = y % 400 */
    cbz     w0, .Lis_leap          /* y%400==0 → leap */

.Lnot_leap:
    mov     w0, #0
    ret
.Lis_leap:
    mov     w0, #1
    ret

/*
 * http_write_2digits — Write a 2-digit decimal number
 *
 * w0: value (0-99)
 * x1: output pointer (2 bytes)
 * Clobbers: w0, w2-w3
 */
http_write_2digits:
    mov     w2, #10
    udiv    w3, w0, w2             /* tens */
    msub    w0, w3, w2, w0         /* ones */
    add     w3, w3, #'0'
    add     w0, w0, #'0'
    strb    w3, [x1]
    strb    w0, [x1, #1]
    ret

/*
 * http_write_4digits — Write a 4-digit decimal number
 *
 * w0: value (0-9999)
 * x1: output pointer (4 bytes)
 * Clobbers: w0, w2-w4
 */
http_write_4digits:
    /* thousands */
    mov     w2, #1000
    udiv    w3, w0, w2
    msub    w0, w3, w2, w0
    add     w3, w3, #'0'
    strb    w3, [x1]

    /* hundreds */
    mov     w2, #100
    udiv    w3, w0, w2
    msub    w0, w3, w2, w0
    add     w3, w3, #'0'
    strb    w3, [x1, #1]

    /* tens */
    mov     w2, #10
    udiv    w3, w0, w2
    msub    w0, w3, w2, w0
    add     w3, w3, #'0'
    strb    w3, [x1, #2]

    /* ones */
    add     w0, w0, #'0'
    strb    w0, [x1, #3]
    ret

/* ===================================================================
 * Lookup tables
 * =================================================================== */
.section .rodata

.balign 4
http_dow_names:
    .ascii  "Sun\0"
    .ascii  "Mon\0"
    .ascii  "Tue\0"
    .ascii  "Wed\0"
    .ascii  "Thu\0"
    .ascii  "Fri\0"
    .ascii  "Sat\0"

.balign 4
http_month_names:
    .ascii  "Jan\0"
    .ascii  "Feb\0"
    .ascii  "Mar\0"
    .ascii  "Apr\0"
    .ascii  "May\0"
    .ascii  "Jun\0"
    .ascii  "Jul\0"
    .ascii  "Aug\0"
    .ascii  "Sep\0"
    .ascii  "Oct\0"
    .ascii  "Nov\0"
    .ascii  "Dec\0"

/* Days per month (non-leap). February gets +1 at runtime for leap years. */
.balign 4
http_month_days:
    .byte   31      /* Jan */
    .byte   28      /* Feb (29 in leap year) */
    .byte   31      /* Mar */
    .byte   30      /* Apr */
    .byte   31      /* May */
    .byte   30      /* Jun */
    .byte   31      /* Jul */
    .byte   31      /* Aug */
    .byte   30      /* Sep */
    .byte   31      /* Oct */
    .byte   30      /* Nov */
    .byte   31      /* Dec */
