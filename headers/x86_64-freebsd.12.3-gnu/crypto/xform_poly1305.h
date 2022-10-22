/* This file is in the public domain. */
/* $FreeBSD: releng/12.3/sys/opencrypto/xform_poly1305.h 337939 2018-08-17 00:30:04Z cem $ */
#pragma once

#include <sys/types.h>

struct poly1305_xform_ctx;

void Poly1305_Init(struct poly1305_xform_ctx *);

void Poly1305_Setkey(struct poly1305_xform_ctx *,
    const uint8_t [__min_size(32)], size_t);

int Poly1305_Update(struct poly1305_xform_ctx *, const void *, size_t);

void Poly1305_Final(uint8_t [__min_size(16)], struct poly1305_xform_ctx *);
