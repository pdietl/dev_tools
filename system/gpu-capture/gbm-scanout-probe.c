/*
 * Measure how many scanout-capable buffers of a given geometry the GPU will
 * hand a fresh client.
 *
 * nvidia-drm refuses every scanout allocation it cannot satisfy with the same
 * message and a bare -EINVAL, and scanout allocations have no system-memory
 * fallback, so a refusal is fatal to the caller on the first attempt. Total
 * free video memory does not predict a refusal: what a compositor needs is one
 * contiguous buffer the size of the panel, and that can be unobtainable while
 * hundreds of megabytes remain free in smaller pieces. This reports the number
 * that does predict it.
 *
 * Allocation needs no DRM master -- only mode-setting does -- so this is safe
 * to run against a live display. Every buffer is released before exit.
 *
 * usage: gbm-scanout-probe <card> <width> <height> [max]
 * exit:  0 measurement completed, 2 device could not be opened
 */
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_MAX 16

int main(int argc, char **argv)
{
	if (argc < 4 || argc > 5) {
		fprintf(stderr,
			"usage: %s <card> <width> <height> [max]\n", argv[0]);
		return 2;
	}

	const char *path = argv[1];
	uint32_t w = (uint32_t)strtoul(argv[2], NULL, 10);
	uint32_t h = (uint32_t)strtoul(argv[3], NULL, 10);
	int max = argc == 5 ? atoi(argv[4]) : DEFAULT_MAX;

	if (!w || !h || max < 1) {
		fprintf(stderr, "%s: width, height and max must be positive\n",
			argv[0]);
		return 2;
	}

	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "%s: open %s: %s\n",
			argv[0], path, strerror(errno));
		return 2;
	}

	struct gbm_device *dev = gbm_create_device(fd);
	if (!dev) {
		fprintf(stderr, "%s: gbm_create_device %s failed\n",
			argv[0], path);
		close(fd);
		return 2;
	}

	struct gbm_bo **bos = calloc((size_t)max, sizeof(*bos));
	if (!bos) {
		fprintf(stderr, "%s: out of memory\n", argv[0]);
		gbm_device_destroy(dev);
		close(fd);
		return 2;
	}

	int got = 0;
	for (int i = 0; i < max; i++) {
		bos[i] = gbm_bo_create(dev, w, h, GBM_FORMAT_XRGB8888,
				       GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
		if (!bos[i])
			break;
		got++;
	}

	printf("%ux%u XRGB8888 scanout: %d/%d buffers (%.1f MiB each) on %s\n",
	       w, h, got, max, (double)w * h * 4 / (1024 * 1024), path);

	for (int i = 0; i < got; i++)
		gbm_bo_destroy(bos[i]);
	free(bos);
	gbm_device_destroy(dev);
	close(fd);
	return 0;
}
