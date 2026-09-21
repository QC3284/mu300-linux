// Dump physical memory or MMIO to dmesg. This kernel has no CONFIG_DEVMEM, so there is no other way to look at
// the AGDSP's reserved region or at the syscon registers sprd_audcp_boot writes through regmap.
//   insmod mu300_peek.ko addr=0xafa00000 len=64          DDR, for "did the firmware land"
//   insmod mu300_peek.ko addr=0x64910b80 len=48 mmio=1   registers, for "did the write take"
// init returns an error on purpose: the dump has already happened, and failing to load means the next insmod
// does not have to rmmod first.
#include <linux/module.h>
#include <linux/io.h>

static unsigned long addr = 0xafa00000;
static unsigned int len = 64;
static int mmio;
module_param(addr, ulong, 0644);
module_param(len, uint, 0644);
module_param(mmio, int, 0644);

static int __init peek_init(void)
{
	void __iomem *io = NULL;
	void *p = NULL;
	const void *src;

	if (len > 512)
		len = 512;
	if (mmio) {
		io = ioremap(addr, len);
		src = (const void __force *)io;
	} else {
		p = memremap(addr, len, MEMREMAP_WB);
		src = p;
	}
	if (!src) {
		pr_err("mu300_peek: map %#lx failed\n", addr);
		return -ENOMEM;
	}
	pr_info("mu300_peek: %#lx +%u %s\n", addr, len, mmio ? "mmio" : "ddr");
	print_hex_dump(KERN_INFO, "mu300_peek: ", DUMP_PREFIX_OFFSET, 16, 4, src, len, false);
	if (io)
		iounmap(io);
	if (p)
		memunmap(p);
	return -EAGAIN;
}
module_init(peek_init);
MODULE_LICENSE("GPL");
