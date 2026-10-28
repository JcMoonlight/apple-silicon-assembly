// =============================================================================
//  calc.s  -  Interactive calculator in ARM64 (AArch64) assembly
//  Target  :  macOS on Apple Silicon (M1/M2/M3), Clang integrated assembler
//  Numbers :  64-bit double-precision floating point (d registers)
// =============================================================================
//
//  PSEUDOCODE (what the program does, in C-like form)
//  --------------------------------------------------
//  main_loop:
//      menu_loop:
//          print menu
//          ch = read_choice()            // reads ONE line, returns 1 char or 0
//          ch = to_upper(ch)
//          if ch < 'A' or ch > 'D':  print error; goto menu_loop
//      get_numbers:
//          a = read_number("first")      // loops internally until valid
//          b = read_number("second")     // loops internally until valid
//          if ch == 'D' and b == 0.0:  print error; goto get_numbers
//          result = a (op) b
//          print "Result: %g"
//      ask_again:
//          print "Do you want to perform another calculation? (Y/N): "
//          ch = to_upper(read_choice())
//          if ch == 'Y': goto main_loop
//          if ch == 'N': exit(0)
//          print error; goto ask_again
//
//  Any time stdin hits EOF (Ctrl+D) the program says goodbye and exits 0,
//  instead of looping forever on an input that can never arrive.
//
// -----------------------------------------------------------------------------
//  REGISTER USAGE
// -----------------------------------------------------------------------------
//  Register  Role
//  --------  ------------------------------------------------------------------
//  x0 - x7   Function arguments / return value (caller-saved: a call may
//            destroy them). w0 is the lower 32 bits of x0.
//  x19       (callee-saved) _main: the chosen operation, 'A'..'D'
//            read_number: pointer to the prompt string
//            read_choice: the character that was typed
//  d8        (callee-saved) _main: first number
//  d9        (callee-saved) _main: second number
//  d0        Floating-point result / return value
//  x29 (fp)  Frame pointer: marks the base of the current stack frame
//  x30 (lr)  Link register: the return address, written by every `bl`
//  sp        Stack pointer: MUST be 16-byte aligned whenever we call a function
//
//  "Callee-saved" means: if a function wants to use x19-x28 or d8-d15 it must
//  save the old value first and restore it before returning. That is what lets
//  x19, d8 and d9 survive across calls to _printf/_scanf/_getchar.
//
// -----------------------------------------------------------------------------
//  STACK FRAME OF _main (48 bytes, higher addresses at the top)
// -----------------------------------------------------------------------------
//        +----------------------+  <- sp before prologue (16-byte aligned)
//        | d9   (second number) |  sp + 40
//        | d8   (first number)  |  sp + 32
//        | padding              |  sp + 24  (keeps the size a multiple of 16)
//        | x19  (operation)     |  sp + 16
//        | x30  (return addr)   |  sp +  8
//        | x29  (old frame ptr) |  sp +  0  <- sp and x29 after prologue
//        +----------------------+
//
// -----------------------------------------------------------------------------
//  macOS ARM64 CALLING-CONVENTION NOTES (important, differs from Linux!)
// -----------------------------------------------------------------------------
//  * printf and scanf are "variadic" functions (they take "..." arguments).
//    On Apple ARM64, every variadic argument is passed ON THE STACK, not in
//    registers. Only the fixed first argument (the format string) goes in x0.
//      - printf("%g", value): store the double at [sp] before the call.
//      - scanf("%lf", &x)   : store the pointer &x at [sp] before the call.
//    (On Linux ARM64 you would use d0 / x1 instead. Do NOT do that here.)
//  * Each such call needs the stack space reserved with `sub sp, sp, #16`
//    (16 and not 8, to keep sp 16-byte aligned) and released afterwards.
//  * C `int` results (scanf's return value, getchar's return value) come back
//    in w0. We compare w0, not x0, because only the lower 32 bits are defined.
//  * Symbol names get a leading underscore on macOS: _main, _printf, ...
//  * Addresses use two instructions (position-independent code):
//        adrp x0, label@PAGE         // load the 4 KB page that holds label
//        add  x0, x0, label@PAGEOFF  // add the offset inside that page
// =============================================================================

        // ---- Character constants (ASCII codes) ----
        .equ    CH_NEWLINE, 10          // '\n'
        .equ    CH_A, 65                // 'A'
        .equ    CH_D, 68                // 'D'
        .equ    CH_B, 66                // 'B'
        .equ    CH_C, 67                // 'C'
        .equ    CH_N, 78                // 'N'
        .equ    CH_Y, 89                // 'Y'
        .equ    CH_a_LOWER, 97          // 'a'
        .equ    CH_z_LOWER, 122         // 'z'
        .equ    CASE_DIFF, 32           // 'a' - 'A'  (lower -> upper)

// =============================================================================
//  TEXT (read-only data): all the strings live here
// =============================================================================
        .section __TEXT,__cstring,cstring_literals

str_menu:
        .asciz  "\n=== ARM64 Assembly Calculator ===\n  A) Addition\n  B) Subtraction\n  C) Multiplication\n  D) Division\nChoose an operation (A/B/C/D): "
str_err_op:
        .asciz  "Error: Invalid operation. Please enter A, B, C, or D.\n"
str_prompt1:
        .asciz  "Enter the first number: "
str_prompt2:
        .asciz  "Enter the second number: "
str_err_num:
        .asciz  "Error: Invalid number. Please try again.\n"
str_err_div:
        .asciz  "Error: Division by zero is not allowed!\n"
str_again:
        .asciz  "Do you want to perform another calculation? (Y/N): "
str_err_yn:
        .asciz  "Error: Invalid choice. Please enter Y or N.\n"
str_bye:
        .asciz  "Goodbye!\n"
str_eof:
        .asciz  "\nEnd of input reached. Goodbye!\n"
fmt_lf:
        .asciz  "%lf"                   // scanf format: read a double
fmt_result:
        .asciz  "Result: %g\n"          // printf format: print a double

// =============================================================================
//  CODE
// =============================================================================
        .text
        .globl  _main
        .p2align 2                      // align code to 4 bytes (instruction size)

// -----------------------------------------------------------------------------
//  _main  -  program entry point
// -----------------------------------------------------------------------------
_main:
        // ---- Prologue: build the stack frame ----
        stp     x29, x30, [sp, #-48]!   // push fp + lr, sp -= 48 (pre-indexed)
        mov     x29, sp                 // frame pointer = current sp
        str     x19, [sp, #16]          // save callee-saved x19 (we use it)
        stp     d8, d9, [sp, #32]       // save callee-saved d8, d9 (we use them)

main_loop:                              // <-- start of one full calculation

// ---------------------------- 1. OPERATION MENU ------------------------------
menu_loop:
        adrp    x0, str_menu@PAGE       // x0 = address of the menu text
        add     x0, x0, str_menu@PAGEOFF
        bl      _printf                 // print menu (no extra args, so no stack args)

        bl      read_choice             // w0 = typed character, or 0 if the line was invalid
        bl      to_upper                // w0 = upper-case version

        cmp     w0, #CH_A               // below 'A'? (also catches 0 = invalid line)
        b.lt    bad_operation           //   yes -> invalid
        cmp     w0, #CH_D               // above 'D'?
        b.gt    bad_operation           //   yes -> invalid

        mov     w19, w0                 // keep the operation in callee-saved w19
        b       get_numbers             // valid -> go read numbers

bad_operation:
        adrp    x0, str_err_op@PAGE
        add     x0, x0, str_err_op@PAGEOFF
        bl      _printf                 // "Error: Invalid operation..."
        b       menu_loop               // (read_choice already flushed the line) re-prompt

// ------------------------- 2 + 3. READ THE TWO NUMBERS -----------------------
get_numbers:
        adrp    x0, str_prompt1@PAGE    // argument: which prompt to show
        add     x0, x0, str_prompt1@PAGEOFF
        bl      read_number             // loops until valid; result in d0
        fmov    d8, d0                  // d8 = first number (callee-saved)

        adrp    x0, str_prompt2@PAGE
        add     x0, x0, str_prompt2@PAGEOFF
        bl      read_number             // loops until valid; result in d0
        fmov    d9, d0                  // d9 = second number (callee-saved)

// ---------------------------- 4. ARITHMETIC ----------------------------------
        cmp     w19, #CH_A              // Addition?
        b.eq    do_add
        cmp     w19, #CH_B              // Subtraction?
        b.eq    do_sub
        cmp     w19, #CH_C              // Multiplication?
        b.eq    do_mul
        b       do_div                  // otherwise it must be 'D'

do_add:
        fadd    d0, d8, d9              // d0 = d8 + d9
        b       print_result
do_sub:
        fsub    d0, d8, d9              // d0 = d8 - d9
        b       print_result
do_mul:
        fmul    d0, d8, d9              // d0 = d8 * d9
        b       print_result

do_div:
        fcmp    d9, #0.0                // compare denominator with 0.0
        b.eq    div_by_zero             // equal -> refuse to divide
                                        // (-0.0 also compares equal to 0.0)
        fdiv    d0, d8, d9              // d0 = d8 / d9
        b       print_result

div_by_zero:
        adrp    x0, str_err_div@PAGE
        add     x0, x0, str_err_div@PAGEOFF
        bl      _printf                 // "Error: Division by zero..."
        b       get_numbers             // re-prompt BOTH numbers (not the menu)

// --------------------------- 5. PRINT THE RESULT -----------------------------
print_result:
        sub     sp, sp, #16             // reserve 16 bytes for the variadic argument
        str     d0, [sp]                // variadic double goes on the STACK (Apple ABI)
        adrp    x0, fmt_result@PAGE     // x0 = format string "Result: %g\n"
        add     x0, x0, fmt_result@PAGEOFF
        bl      _printf
        add     sp, sp, #16             // release the 16 bytes

// ------------------------ CONTINUATION QUESTION (Y/N) ------------------------
ask_again:
        adrp    x0, str_again@PAGE
        add     x0, x0, str_again@PAGEOFF
        bl      _printf                 // "Do you want to perform another..."

        bl      read_choice             // w0 = typed char or 0
        bl      to_upper

        cmp     w0, #CH_Y
        b.eq    main_loop               // Y -> start over at the menu
        cmp     w0, #CH_N
        b.eq    quit                    // N -> leave

        adrp    x0, str_err_yn@PAGE
        add     x0, x0, str_err_yn@PAGEOFF
        bl      _printf                 // invalid answer
        b       ask_again               // (line already flushed) ask again

quit:
        adrp    x0, str_bye@PAGE
        add     x0, x0, str_bye@PAGEOFF
        bl      _printf                 // "Goodbye!"

        // ---- Epilogue: undo the prologue in reverse order ----
        ldp     d8, d9, [sp, #32]
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #48     // post-indexed: pop and sp += 48
        mov     w0, #0                  // return code 0 = success
        ret                             // jump to address in x30

// -----------------------------------------------------------------------------
//  exit_eof  -  called (by branch) when stdin reaches end-of-file
//  Never returns: prints a message and ends the process with exit code 0.
//  sp is already 16-byte aligned wherever we branch here from.
// -----------------------------------------------------------------------------
exit_eof:
        adrp    x0, str_eof@PAGE
        add     x0, x0, str_eof@PAGEOFF
        bl      _printf
        mov     w0, #0                  // exit status 0
        bl      _exit                   // C library exit(): flushes output, ends program

// -----------------------------------------------------------------------------
//  read_number
//    In : x0 = address of the prompt string
//    Out: d0 = the number the user typed (always valid when we return)
//  Keeps asking until scanf("%lf") succeeds. Only THIS number is re-prompted.
//
//  Frame (32 bytes):  sp+0 fp | sp+8 lr | sp+16 saved x19 | sp+24 scratch double
// -----------------------------------------------------------------------------
read_number:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]          // save callee-saved x19
        mov     x19, x0                 // x19 = prompt string (survives the calls)

rn_retry:
        mov     x0, x19                 // x0 = prompt text
        bl      _printf                 // show the prompt

        adrp    x0, fmt_lf@PAGE         // x0 = "%lf"
        add     x0, x0, fmt_lf@PAGEOFF
        add     x1, x29, #24            // x1 = address of our scratch double (sp+24)
        sub     sp, sp, #16             // reserve space for the variadic argument
        str     x1, [sp]                // pointer argument goes on the STACK (Apple ABI)
        bl      _scanf                  // w0 = number of items converted (or -1 on EOF)
        add     sp, sp, #16             // release the argument space

        cmp     w0, #1                  // success = exactly one value read
        b.eq    rn_ok
        cmn     w0, #1                  // w0 == -1 (EOF)?  (cmn adds, so w0 + 1 == 0)
        b.eq    exit_eof                // yes -> no more input will ever come

        // scanf returned 0: the text was not a number
        adrp    x0, str_err_num@PAGE
        add     x0, x0, str_err_num@PAGEOFF
        bl      _printf                 // "Error: Invalid number..."
        bl      flush_input             // throw away the rest of the bad line
        b       rn_retry                // ask for this same number again

rn_ok:
        bl      flush_input             // discard leftovers such as "\n" or the "abc" of "12abc"
        ldr     d0, [x29, #24]          // d0 = the number scanf stored
        ldr     x19, [sp, #16]          // restore x19
        ldp     x29, x30, [sp], #32     // pop frame
        ret

// -----------------------------------------------------------------------------
//  read_choice
//    Reads ONE whole line from the keyboard and returns the single character
//    on it.
//    Out: w0 = the character, or 0 if the line was empty or longer than one
//         character (the rest of that line has already been flushed).
//    EOF  : exits the program.
//  Frame (32 bytes):  sp+0 fp | sp+8 lr | sp+16 saved x19
// -----------------------------------------------------------------------------
read_choice:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]

        bl      _getchar                // first character of the line
        cmn     w0, #1                  // EOF?
        b.eq    exit_eof
        cmp     w0, #CH_NEWLINE         // empty line (just Enter)?
        b.eq    rc_invalid              // yes: the line is already consumed
        mov     w19, w0                 // remember the first character

        bl      _getchar                // second character should be '\n'
        cmn     w0, #1                  // "X" then EOF: accept X
        b.eq    rc_valid
        cmp     w0, #CH_NEWLINE         // exactly one character + Enter?
        b.eq    rc_valid

        bl      flush_input             // more than one character: eat the rest of the line
rc_invalid:
        mov     w0, #0                  // 0 means "invalid"
        b       rc_done
rc_valid:
        mov     w0, w19                 // return the typed character
rc_done:
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// -----------------------------------------------------------------------------
//  flush_input
//    Assembly version of:   while ((c = getchar()) != '\n' && c != EOF);
//    Reads and throws away characters up to and including the next newline.
// -----------------------------------------------------------------------------
flush_input:
        stp     x29, x30, [sp, #-16]!   // needed because we call _getchar
        mov     x29, sp
fi_loop:
        bl      _getchar                // w0 = next character (or -1)
        cmn     w0, #1                  // EOF?
        b.eq    fi_done                 // yes -> stop
        cmp     w0, #CH_NEWLINE         // end of line?
        b.ne    fi_loop                 // no -> keep discarding
fi_done:
        ldp     x29, x30, [sp], #16
        ret

// -----------------------------------------------------------------------------
//  to_upper  -  leaf function (calls nothing, so no stack frame needed)
//    In/Out: w0 = character; 'a'..'z' becomes 'A'..'Z', everything else is
//            returned unchanged.
// -----------------------------------------------------------------------------
to_upper:
        cmp     w0, #CH_a_LOWER         // below 'a'?
        b.lt    tu_done                 // yes: leave as is
        cmp     w0, #CH_z_LOWER         // above 'z'?
        b.gt    tu_done                 // yes: leave as is
        sub     w0, w0, #CASE_DIFF      // 'a'(97) - 32 = 'A'(65)
tu_done:
        ret

// =============================================================================
//  HOW TO BUILD AND RUN (in Terminal on an Apple Silicon Mac)
// =============================================================================
//  Easiest (clang assembles AND links for you):
//
//      clang -arch arm64 calc.s -o calc
//      ./calc
//      echo $?              # prints the exit code (0 after a normal exit)
//
//  Step by step, using the assembler and linker directly:
//
//      as -arch arm64 calc.s -o calc.o
//      ld -arch arm64 -platform_version macos 11.0 11.0 \
//         -syslibroot "$(xcrun -sdk macosx --show-sdk-path)" \
//         -lSystem -e _main calc.o -o calc
//      ./calc
//
//  Needs the Xcode Command Line Tools:   xcode-select --install
//
//  Debugging tip (lldb ships with the tools):
//
//      clang -arch arm64 -g calc.s -o calc
//      lldb ./calc          then:  b _main   /   run   /   si (step instruction)
//                                  register read   /   register read d8 d9
// =============================================================================
