/*
 * $FreeBSD: releng/12.3/sys/sys/ck.h 369612 2021-04-15 23:06:02Z git2svn $
 */
#ifndef _SYS_CK_H_
#define _SYS_CK_H_

#ifdef _KERNEL
#include <ck_queue.h>
#include <ck_epoch.h>
#else
#include <sys/queue.h>
#define CK_STAILQ_HEAD STAILQ_HEAD
#define CK_STAILQ_ENTRY STAILQ_ENTRY
#define CK_LIST_HEAD LIST_HEAD
#define CK_LIST_ENTRY LIST_ENTRY
#endif

#endif /* !_SYS_CK_H_ */
