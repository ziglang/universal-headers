/*	$FreeBSD: releng/12.3/sys/contrib/ipfilter/netinet/ip_rules.h 369247 2021-02-09 13:48:26Z git2svn $	*/

extern int ipfrule_add(void);
extern int ipfrule_remove(void);

extern frentry_t *ipfrule_match_out_(fr_info_t *, u_32_t *);
extern frentry_t *ipf_rules_out_[1];

extern int ipfrule_add_out_(void);
extern int ipfrule_remove_out_(void);

extern frentry_t *ipfrule_match_in_(fr_info_t *, u_32_t *);
extern frentry_t *ipf_rules_in_[1];

extern int ipfrule_add_in_(void);
extern int ipfrule_remove_in_(void);
