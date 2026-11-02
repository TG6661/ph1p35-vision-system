#ifndef TARGET_IO_H
#define TARGET_IO_H
#include "fabric_regs.h"
/* Test callbacks exercise the real service state machine, including MMIO order.
 * Production remains ordinary volatile AHB accesses, with no callback cost. */
#ifdef OOPFPGA_TARGET_IO_TEST
uint32_t target_test_read(unsigned offset);
void target_test_write(unsigned offset,uint32_t value);
#define TARGET_READ(reg) target_test_read((unsigned)(&(reg)-fabric_test_mmio)*4u)
#define TARGET_WRITE(reg,value) target_test_write((unsigned)(&(reg)-fabric_test_mmio)*4u,(value))
#else
#define TARGET_READ(reg) (reg)
#define TARGET_WRITE(reg,value) ((reg)=(value))
#endif
#endif
