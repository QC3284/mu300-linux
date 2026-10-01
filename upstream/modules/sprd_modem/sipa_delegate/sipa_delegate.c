// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (C) 2019 Spreadtrum Communications Inc.
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#ifdef pr_fmt
#undef pr_fmt
#endif
#define pr_fmt(fmt) "sipa_dele: " fmt

#include <linux/device.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/sipa.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/io.h>
#include <linux/cdev.h>
#include "sipa_delegate.h"
#include "sipa_dele_priv.h"

#define DRV_NAME "sipa_delegate"

static struct sipa_delegate_plat_drv_cfg s_sipa_dele_cfg;

/*
 * v8c7: this device's DT has no mem-base/reg-base on the sipa-dele node at all.
 *
 * Verified on the runtime blobs (f50_kernel/device/base_dtb.bin, fdt.bin and the FDT inside
 * vendor_boot_a.img): the node carries only the compatible, the two fifo depths and
 * power-domains - "mem-base" and "reg-base" appear nowhere in those trees. The stock 5.4 DTS is
 * identical, and no other driver adds the resources (no platform_device_add_resources anywhere
 * in the sipa tree), so waiting for them can never succeed.
 *
 * Nothing in this driver reads cfg->mem_base/reg_base after parse, so fall back to the sibling
 * IPA node's region (sipa@25220000, reg-names = "ipa-base"); keep the deferral only for the case
 * where even that is unavailable.
 */
static int sipa_dele_fallback_base(struct platform_device *pdev, struct resource *out)
{
	struct device_node *parent, *child;
	int ret = -ENODEV;

	parent = of_get_parent(pdev->dev.of_node);
	if (!parent)
		return -ENODEV;

	for_each_child_of_node(parent, child) {
		if (child == pdev->dev.of_node)
			continue;
		if (!of_find_property(child, "reg-names", NULL))
			continue;
		ret = of_address_to_resource(child, 0, out);
		if (!ret) {
			dev_info(&pdev->dev, "no mem-base/reg-base in DT, using sibling ipa-base 0x%llx\n",
				 (unsigned long long)out->start);
			of_node_put(child);
			break;
		}
	}

	of_node_put(parent);
	return ret;
}

static int sipa_dele_parse_dts_cfg(struct platform_device *pdev,
				   struct sipa_delegate_plat_drv_cfg *cfg)
{
	int ret;
	struct resource *resource;

	/* get modem IPA global register base  address */
	resource = platform_get_resource_byname(pdev,
					IORESOURCE_MEM,
					"mem-base");
	if (!resource) {
		/* v8c7: not in this DT (see sipa_dele_fallback_base) - fall back instead of waiting. */
		struct resource fb;
		if (sipa_dele_fallback_base(pdev, &fb)) {
			/* v8c7 stock semantics: the stock 5.4 driver logs the same failure and still
			 * lets the initcall return 0 (module stays resident) and the smsg/pd handshake
			 * proceed. Do not defer and do not fail: warn and continue with zeros. */
			dev_warn(&pdev->dev, "no mem-base in DT, continuing (stock semantics)\n");
		} else {
			cfg->mem_base = fb.start;
			cfg->mem_end = fb.end;
		}
	} else {
		cfg->mem_base = resource->start;
		cfg->mem_end = resource->end;
	}

	/* get mapped modem IPA global register base  address */
	resource = platform_get_resource_byname(pdev,
					IORESOURCE_MEM,
					"reg-base");
	if (!resource) {
		struct resource fb;
		if (sipa_dele_fallback_base(pdev, &fb)) {
			dev_warn(&pdev->dev, "no reg-base in DT, continuing (stock semantics)\n");
		} else {
			cfg->reg_base = fb.start;
			cfg->reg_end = fb.end;
		}
	} else {
		cfg->reg_base = resource->start;
		cfg->reg_end = resource->end;
	}

	/* get ul fifo depth */
	ret = of_property_read_u32(pdev->dev.of_node,
				   "sprd,ul-fifo-depth",
				   &cfg->ul_fifo_depth);
	if (ret) {
		dev_info(&pdev->dev, "ul-fifo-depth not ready, deferring\n");
		return -EPROBE_DEFER;
	}

	/* get dl fifo depth */
	ret = of_property_read_u32(pdev->dev.of_node,
				   "sprd,dl-fifo-depth",
				   &cfg->dl_fifo_depth);
	if (ret) {
		dev_info(&pdev->dev, "dl-fifo-depth not ready, deferring\n");
		return -EPROBE_DEFER;
	}

	return 0;
}

/*
 * v8c5: the delegate must not spend the boot waiting for CP-side resources.
 *
 * Before: probe returned -ENODEV when mem-base/reg-base were not there yet, which is permanent -
 *         the module stayed loaded but unbound, and the only retry was another insmod from user
 *         space, each of which blocked the caller for a long time (86 s observed in the initramfs
 *         extra-modules loop).
 * After:  probe returns -EPROBE_DEFER immediately (no waiting at all) and a delayed work retries
 *         the rendezvous every 5 s for up to 180 s; the module stays loaded throughout, so the
 *         early load in the initramfs is preserved without burning the boot budget.
 * The user space path (/opt/mu300/bin/sipa-dele-start) remains the final fallback.
 */
#define SIPA_DELE_RETRY_SECS 5
#define SIPA_DELE_RETRY_MAX  36   /* 36 * 5 s = 180 s */

static struct delayed_work s_dele_retry;
static struct platform_device *s_dele_pdev;
static int s_dele_retry_left;
static bool s_dele_ready;

/* v8c9: 握手一旦完成就不要再重跑 setup —— 每次重跑都会再开一次通道(CP 未就绪时就是 -62)。 */
void sipa_dele_retry_stop(void)
{
	cancel_delayed_work(&s_dele_retry);
}
EXPORT_SYMBOL_GPL(sipa_dele_retry_stop);
static DEFINE_MUTEX(s_dele_lock);

static int sipa_dele_setup(struct platform_device *pdev_p)
{
	int ret;
	struct device *dev = &pdev_p->dev;
	struct sipa_delegate_plat_drv_cfg *cfg = &s_sipa_dele_cfg;
	struct sipa_delegator_create_params create_params;

	if (!sipa_rm_is_initialized()) {
		dev_info(dev, "sipa rm not ready, deferring\n");
		return -EPROBE_DEFER;
	}

	memset(cfg, 0, sizeof(*cfg));

	ret = sipa_dele_parse_dts_cfg(pdev_p, cfg);
	if (ret) {
		dev_info(dev, "dts not ready yet: %d\n", ret);
		return ret;
	}

	create_params.pdev = dev;
	create_params.cfg = cfg;
	create_params.chan = SMSG_CH_COMM_SIPA;

	create_params.prod_id = SIPA_RM_RES_PROD_CP;
	create_params.cons_prod = SIPA_RM_RES_CONS_WWAN_UL;
	create_params.cons_user = SIPA_RM_RES_CONS_WWAN_DL;
	create_params.dst = SIPC_ID_PSCP;

	ret = cp_delegator_init(&create_params);
	if (ret) {
		dev_err(dev, "cp_delegator_init failed: %d\n", ret);
		return ret;
	}
	pr_debug("cp_delegator_init!\n");

	return 0;
}

static void sipa_dele_retry_work(struct work_struct *work)
{
	struct platform_device *pdev = s_dele_pdev;
	int ret;

	if (!pdev)
		return;

	mutex_lock(&s_dele_lock);
	if (s_dele_ready) {
		mutex_unlock(&s_dele_lock);
		return;
	}
	if (s_dele_retry_left <= 0) {
		mutex_unlock(&s_dele_lock);
		dev_info(&pdev->dev, "delegate still not ready after %d s, giving up (user space retries)\n",
			 SIPA_DELE_RETRY_SECS * SIPA_DELE_RETRY_MAX);
		return;
	}
	s_dele_retry_left--;
	ret = sipa_dele_setup(pdev);
	if (!ret) {
		s_dele_ready = true;
		mutex_unlock(&s_dele_lock);
		dev_info(&pdev->dev, "delegate ready after retries\n");
		return;
	}
	mutex_unlock(&s_dele_lock);

	if (ret == -EPROBE_DEFER)
		schedule_delayed_work(&s_dele_retry,
				      msecs_to_jiffies(SIPA_DELE_RETRY_SECS * 1000));
}

static int sipa_dele_plat_drv_probe(struct platform_device *pdev_p)
{
	int ret;

	mutex_lock(&s_dele_lock);
	if (s_dele_ready) {           /* the retry work already set it up */
		mutex_unlock(&s_dele_lock);
		return 0;
	}
	s_dele_pdev = pdev_p;
	s_dele_retry_left = SIPA_DELE_RETRY_MAX;
	ret = sipa_dele_setup(pdev_p);
	if (!ret) {
		s_dele_ready = true;
		mutex_unlock(&s_dele_lock);
		return 0;
	}
	mutex_unlock(&s_dele_lock);

	/* Never block the caller here: arm the retry work and defer. */
	if (ret == -EPROBE_DEFER) {
		dev_info(&pdev_p->dev, "resources not ready, deferring (module stays loaded)\n");
		schedule_delayed_work(&s_dele_retry,
				      msecs_to_jiffies(SIPA_DELE_RETRY_SECS * 1000));
	}
	return ret;
}

static const struct of_device_id sipa_dele_plat_drv_match[] = {
	{ .compatible = "sprd,roc1-sipa-delegate", },
	{ .compatible = "sprd,orca-sipa-delegate", },
	{}
};

/**
 * sipa_dele_ap_suspend() - suspend callback for runtime_pm
 * @dev: pointer to device
 *
 * This callback will be invoked by the runtime_pm framework when an AP suspend
 * operation is invoked.
 *
 * Returns -EAGAIN to runtime_pm framework in case IPA is in use by AP.
 * This will postpone the suspend operation until IPA is no longer used by AP.
 */
static int sipa_dele_ap_suspend(struct device *dev)
{
	return 0;
}

/**
 * sipa_dele_ap_resume() - resume callback for runtime_pm
 * @dev: pointer to device
 *
 * This callback will be invoked by the runtime_pm framework when an AP resume
 * operation is invoked.
 *
 * Always returns 0 since resume should always succeed.
 */
static int sipa_dele_ap_resume(struct device *dev)
{
	return 0;
}

static const struct dev_pm_ops sipa_dele_pm_ops = {
	.suspend_noirq = sipa_dele_ap_suspend,
	.resume_noirq = sipa_dele_ap_resume,
};

static struct platform_driver sipa_dele_plat_drv = {
	.probe = sipa_dele_plat_drv_probe,
	.driver = {
		.name = DRV_NAME,
		.pm = &sipa_dele_pm_ops,
		.of_match_table = sipa_dele_plat_drv_match,
	},
};

static int __init sipa_dele_module_init(void)
{
	/* v8c5: the retry work must be initialized before any probe can schedule it. */
	INIT_DELAYED_WORK(&s_dele_retry, sipa_dele_retry_work);
	/* Register as a platform device driver */
	return platform_driver_register(&sipa_dele_plat_drv);
}

module_init(sipa_dele_module_init);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Spreadtrum IPA Delegate device driver");
