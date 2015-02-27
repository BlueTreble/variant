/*
 * Copyright (c) 2014 Jim Nasby, Blue Treble Consulting http://BlueTreble.com
 */

#ifndef VARIANT_H 
#define VARIANT_H 

typedef struct
{
	int32				vl_len_;		/* varlena header (do not touch directly!) */
	Oid					pOid;				/* Not a plain OID! */
    int                 typmod;
} VariantData;
typedef VariantData *Variant;

/*
 * To be as efficient as possible, variants are represented to the rest of the
 * system with a "Packed Oid" whose high-order bits are flags. Of course, this
 * poses a problem if the OID of an input type is too large; it would
 * over-write our flag bits. If that happens, VAR_OVERFLOW is true and the top
 * 8 bits of the Oid appear in the last byte of the variant. Note that our
 * flags are *always* in the top bits of the Packed Oid, but don't necessarily
 * take the full top 8 bits.
 *
 * Currently we also have a flag to indicate whether the data we were handed is
 * NULL or not. *This is not the same as the variant being NULL!* We support
 * being handed "(int,)", which means we have an int that is NULL. Note that
 * default cast logic will never call a cast function on a null input, so
 * actually supporting this is someone difficult.
 *
 * Funally, VAR_VERSION is used as an internal version indicator. Currently we
 * only support version 0, but if we didn't reserve space for a version
 * identifier pg_upgrade would be in trouble if we ever needed to change our
 * storage format.
 *
 * TODO: Further improve efficiency by not storing the varlena size header if
 * typid is a varlena.
 */

#define VAR_ISNULL					0x20000000
#define VAR_OVERFLOW				0x40000000
#define	VAR_VERSION					0x80000000
#define VAR_FLAGMASK				0xE0000000
#define OID_MASK						0x1FFFFFFF
#define OID_TOO_LARGE(Oid) (Oid > OID_MASK)


#define VHDRSZ				(sizeof(VariantData))
#define VDATAPTR(x)		    ( (Pointer) ( (x) + 1 ) )
#define VDATAPTR_ALIGN(x, typalign)   ( (Pointer) att_align_nominal(VDATAPTR(x), typalign) )

/*
 * Easier to use internal representation. All the fields represent the state of
 * the original data we were handed.
 */
typedef struct {
	Datum					data;
	Oid						typid;
    int                     typmod;

    /* This is the only flag from VariantData that we care about internally. */
	bool					isnull;
} VariantDataInt;
typedef VariantDataInt *VariantInt;

/*
 * fmgr macros for range type objects
 */
#define DatumGetVariantType(X)		((Variant) PG_DETOAST_DATUM(X))
#define DatumGetVariantTypeCopy(X)	((Variant) PG_DETOAST_DATUM_COPY(X))
#define VariantTypeGetDatum(X)		PointerGetDatum(X)
#define PG_GETARG_VARIANT(n)			DatumGetVariantType(PG_GETARG_DATUM(n))
#define PG_GETARG_VARIANT_COPY(n)		DatumGetVariantTypeCopy(PG_GETARG_DATUM(n))
#define PG_RETURN_VARIANT(x)			return VariantTypeGetDatum(x)

#endif   /* VARIANT_H */

