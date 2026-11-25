// SPDX-License-Identifier: GPL-2.0
/*
 * g3core: minimal device-tree platform for the g3core soft PowerPC 750.
 *
 * No interrupt controller: the only interrupt source is the decrementer, and
 * the 16550 UART runs in polling mode. The optional "g3core,simctl" node is
 * the simulator's exit register.
 */
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/of_platform.h>
#include <linux/pm.h>
#include <linux/io.h>
#include <asm/machdep.h>
#include <asm/time.h>
#include <asm/udbg.h>

static void __iomem *g3core_simctl;

static void __noreturn g3core_stop(void)
{
	local_irq_disable();
	if (g3core_simctl)
		out_be32(g3core_simctl + 4, 0);
	for (;;)
		;
}

static void g3core_power_off(void)
{
	g3core_stop();
}

static void __noreturn g3core_restart(char *cmd)
{
	g3core_stop();
}

static unsigned int g3core_get_irq(void)
{
	return 0;	/* no external interrupts */
}

static void __init g3core_init_irq(void)
{
}

static void __init g3core_setup_arch(void)
{
	struct device_node *np;

	np = of_find_compatible_node(NULL, NULL, "g3core,simctl");
	if (np) {
		g3core_simctl = of_iomap(np, 0);
		of_node_put(np);
	}
	pm_power_off = g3core_power_off;
}

static const struct of_device_id g3core_bus_ids[] __initconst = {
	{ .compatible = "simple-bus", },
	{},
};

static int __init g3core_device_probe(void)
{
	of_platform_bus_probe(NULL, g3core_bus_ids, NULL);
	return 0;
}
machine_device_initcall(g3core, g3core_device_probe);

define_machine(g3core) {
	.name		= "g3core",
	.compatible	= "g3core,sim",
	.setup_arch	= g3core_setup_arch,
	.init_IRQ	= g3core_init_irq,
	.get_irq	= g3core_get_irq,
	.restart	= g3core_restart,
	.halt		= g3core_stop,
	.progress	= udbg_progress,
};
