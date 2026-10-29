# ARM64 Calculator: Test Checklist and 32-bit vs 64-bit Lesson

Companion to `calc.s`. Build and run:

```bash
clang -arch arm64 calc.s -o calc
./calc
echo $?        # exit code, should be 0 after quitting
```

---

## Part 1: Test checklist

Type the **Input** column at each prompt, in order. Run the program and tick each row.

### Valid calculations

| # | Input (op, num1, num2) | Expected output |
|---|------------------------|-----------------|
| 1 | `A`, `2`, `3` | `Result: 5` |
| 2 | `b`, `10`, `4.5` | `Result: 5.5` |
| 3 | `C`, `-3`, `2.5` | `Result: -7.5` |
| 4 | `d`, `10`, `4` | `Result: 2.5` |
| 5 | `A`, `0.1`, `0.2` | `Result: 0.3` (`%g` shows 6 significant digits) |
| 6 | `C`, `1e308`, `10` | `Result: inf` (overflow, not a crash) |

### Menu errors (each should print the "Invalid operation" message and show the menu again)

| # | Input | Why it is invalid |
|---|-------|-------------------|
| 7 | `X` | Not A-D |
| 8 | `5` | A digit |
| 9 | `@` | A symbol |
| 10 | `AB` | More than one character |
| 11 | (just press Enter) | Empty line |

### Number errors

| # | Where | Input | Expected |
|---|-------|-------|----------|
| 12 | Number 1 | `abc` | "Invalid number" and **Number 1** is asked again (not the menu) |
| 13 | Number 2 | `xyz` | "Invalid number" and **Number 2** is asked again (Number 1 is kept) |
| 14 | Number 1 | `12abc` | Accepted as `12`; the `abc` is thrown away, so it cannot leak into the next prompt |
| 15 | Number 1 | `-4.25` | Accepted (negative decimals work) |

Note: pressing Enter on an empty line at a *number* prompt just waits. That is normal `scanf` behaviour, because `%lf` skips blank lines.

### Division by zero

| # | Input | Expected |
|---|-------|----------|
| 16 | `D`, `5`, `0` | "Division by zero" message, then **both** numbers are asked again |
| 17 | then `5`, `2` | `Result: 2.5` |
| 18 | `D`, `1`, `-0` | Also caught as zero (`-0.0 == 0.0`) |
| 19 | `D`, `0`, `5` | `Result: 0` (zero as the *numerator* is fine) |

### Continue prompt

| # | Input | Expected |
|---|-------|----------|
| 20 | `y` | Back to the menu |
| 21 | `maybe`, `5`, (Enter) | Error message each time, question is asked again |
| 22 | `n` | "Goodbye!" and exit code `0` (`echo $?`) |

### End of input (EOF)

| # | What to do | Expected |
|---|-----------|----------|
| 23 | Press **Ctrl+D** at the menu | "End of input reached" and exit code `0` (no infinite loop) |
| 24 | Press **Ctrl+D** at a number prompt | Same |
| 25 | Press **Ctrl+D** at the Y/N prompt | Same |
| 26 | `printf 'A\n2\n3\nN\n' \| ./calc` | Full run from piped input, prints `Result: 5`, exits 0 |

### If something crashes

- Crash right at a `printf`/`scanf` call: check that `sp` is 16-byte aligned and that variadic arguments are on the **stack** (this is the usual macOS mistake).
- Crash on `ret`: a function overwrote `x30` without saving it.
- Wrong numbers after a call: a value was kept in a caller-saved register (`x0`-`x15`, `d0`-`d7`) instead of `x19`-`x28` / `d8`-`d15`.

---

## Part 2: 32-bit vs 64-bit assembly, for beginners

### 1. What "32-bit" and "64-bit" mean

A **bit** is a single 0 or 1. A CPU does its work in **registers**, tiny storage slots built into the chip. Think of a register as a **workbench**:

- On a **32-bit** CPU the bench holds a number written with 32 binary digits.
- On a **64-bit** CPU the bench holds 64 binary digits, so it can handle bigger numbers in one step.

The same number also describes **addresses**. Every byte in memory has an address, like a house number on a street.

| | 32-bit | 64-bit |
|---|--------|--------|
| Register width | 32 bits | 64 bits |
| Address width | 32 bits | 64 bits |
| Distinct addresses | 2^32 = about 4.3 billion | 2^64, which is astronomically more |
| Memory a program can use | about 4 GB max | Far beyond any real computer (in practice Apple Silicon uses 48-bit addresses, about 256 TB) |

The old 4 GB ceiling is the main reason the world moved to 64-bit.

### 2. Registers: `x`, `w`, and 32-bit ARM's `r`

On ARM64 there are 31 general-purpose registers, `x0` to `x30`. Each has **two names** for two views of the *same* storage:

```
 x0  : [ upper 32 bits | lower 32 bits ]   <- 64-bit view
 w0  :                 [ lower 32 bits ]   <- 32-bit view
```

- Use **`x`** registers for 64-bit values: pointers/addresses, `long`.
- Use **`w`** registers for 32-bit values: a C `int`.
- **Important rule:** writing to `w0` sets the upper 32 bits of `x0` to **zero**. Writing to `x0` overwrites everything.

Where this shows up in `calc.s`:

```asm
bl   _scanf            // scanf returns an int ...
cmp  w0, #1            // ... so we compare w0 (32 bits)

add  x1, x29, #24      // a memory address (pointer) ... so we use x1 (64 bits)

mov  w19, w0           // the operation letter is a small int, so w19
```

**32-bit ARM** (the older instruction set, "AArch32") is different: it only has `r0` to `r15`, each 32 bits wide, and three of them are special: `r13` = stack pointer, `r14` = link register, `r15` = program counter.

### 3. Floating-point: `s` vs `d`

Decimal numbers use separate floating-point registers, named by size:

| Name | Size | C type | Precision |
|------|------|--------|-----------|
| `s0`-`s31` | 32 bits | `float` | about 7 decimal digits |
| `d0`-`d31` | 64 bits | `double` | about 15-16 decimal digits |

```asm
fadd s0, s1, s2     // add two 32-bit floats
fadd d0, d1, d2     // add two 64-bit doubles  <- what our calculator does
```

Our calculator uses `d` registers because `scanf("%lf")` produces a **double** (the `l` means "long float" = double), and `printf("%g")` expects a double too.

Do not mix up the two ideas: "64-bit ARM" describes the **general** registers and addresses. It does *not* mean "doubles only". A 64-bit CPU happily does 32-bit `float` math in `s` registers.

### 4. Instruction differences: A64 vs old 32-bit ARM

| Task | 32-bit ARM (A32) | 64-bit ARM (A64) |
|------|------------------|------------------|
| Save registers on the stack | `push {r4, lr}` | `stp x19, x30, [sp, #-16]!` |
| Restore and return | `pop {r4, pc}` | `ldp x19, x30, [sp], #16` then `ret` |
| Return from a function | `bx lr` (or write to `pc`) | `ret` |
| Program counter | `r15`, an ordinary register you can write to | Not a general register, changed only by branches |
| Conditional execution | Almost any instruction can be conditional: `addeq r0, r0, r1` | Only branches (`b.eq`) and special selects (`csel`, `cset`) |
| General registers | 16 (`r0`-`r15`) | 31 (`x0`-`x30`) plus `sp` and the zero register `xzr` |
| Stack alignment | 8 bytes | **16 bytes** (hardware-enforced at `sp` accesses) |

In A64 there is **no `push`/`pop`**; you use `stp` (store pair) and `ldp` (load pair). That is why our functions begin with `stp x29, x30, [sp, #-32]!`.

### 5. Data type sizes on 64-bit macOS

macOS uses the **LP64** model: `long` and pointers are 64 bits, but `int` stays 32 bits.

| C type | 32-bit system (ILP32) | 64-bit macOS (LP64) | Register to use |
|--------|----------------------|---------------------|-----------------|
| `char` | 1 byte | 1 byte | `w` |
| `short` | 2 bytes | 2 bytes | `w` |
| `int` | 4 bytes | 4 bytes | `w` |
| `long` | 4 bytes | **8 bytes** | `x` |
| pointer | 4 bytes | **8 bytes** | `x` |
| `float` | 4 bytes | 4 bytes | `s` |
| `double` | 8 bytes | 8 bytes | `d` |

That is exactly why `calc.s` uses `w0` for `scanf`'s `int` result but `x1` for the address of the number.

### 6. Same tiny snippet, side by side

Goal: save a register, compute `5 + 3`, return the result.

```asm
// 32-bit ARM (will NOT assemble on your Mac)
push  {r4, lr}
mov   r4, #5
add   r0, r4, #3
pop   {r4, pc}
```

```asm
// 64-bit ARM, what you use on Apple Silicon
stp   x19, x30, [sp, #-16]!
mov   w19, #5
add   w0, w19, #3
ldp   x19, x30, [sp], #16
ret
```

**Common beginner mistakes**

1. **Mixing `w` and `x` in one instruction.** `add x0, x1, w2` is an error; both sources must be the same width (or use an extend like `add x0, x1, w2, sxtw`).
2. **Forgetting 16-byte stack alignment.** Calling `_printf` with a misaligned `sp` can crash in a confusing place.
3. **Forgetting to save `x30` (`lr`) before a `bl`.** The `bl` overwrites it, so your own `ret` jumps to the wrong place.
4. **Using `x0` for an `int` result.** The upper 32 bits are not guaranteed to be meaningful; compare `w0`.
5. **Keeping a value you need in `x0`-`x15`/`d0`-`d7` across a call.** Those are caller-saved, so any call may wipe them. Use `x19`-`x28` / `d8`-`d15` (and save/restore them).
6. **Passing `printf`/`scanf` extra arguments in registers.** On Apple ARM64, extra (variadic) arguments go on the stack.
7. **Writing `r0` instead of `x0`/`w0`**, or `push`/`pop`: these are 32-bit ARM habits from older tutorials.
8. **Forgetting the underscore:** the symbol is `_main`/`_printf` on macOS.

### 7. Why this matters for your Mac

- Apple Silicon chips (M1, M2, M3 and later) are **64-bit only**. They do not implement the 32-bit ARM instruction set at all.
- macOS itself dropped 32-bit apps in macOS 10.15 Catalina (2019).
- So code written in 32-bit ARM style (`r0`-`r15`, `push`/`pop`, `bx lr`) will fail to assemble or run here, and many tutorials online are 32-bit or Linux-flavoured. When you read one, check: does it use `x`/`w` registers and `stp`/`ldp`? Is it for Linux or macOS? The Linux versus macOS difference matters for system calls and variadic arguments.
