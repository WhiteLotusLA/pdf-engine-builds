/* Smoke test for the PDFium static library built by this repo.
 *
 * Usage:
 *   smoke <file.pdf> --pages N --contains TEXT
 *   smoke <file.pdf> --pages N --contains TEXT --redact NEEDLE --keep TEXT [--skip-apply]
 *
 * Exit codes: 0 all checks passed, 1 a check failed, 2 usage error or unsupported mode.
 * Output is status lines only. The text found in the document is never printed.
 *
 * The --redact mode needs the EmbedPDF patch series (compile with -DSMOKE_EPDF=1). It adds a
 * redact annotation over NEEDLE, calls EPDFPage_ApplyRedactions, saves a full rewrite to memory,
 * reopens it and checks with FPDFText that NEEDLE is gone and TEXT is still there.
 * --skip-apply leaves out the apply call; the run must then FAIL, which proves the check works.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "PDFium/PDFium.h"

/* Returns the page text as a malloc'd ASCII string (other characters become '?'), or NULL. */
static char *page_text(FPDF_PAGE page) {
  FPDF_TEXTPAGE text_page = FPDFText_LoadPage(page);
  if (!text_page) return NULL;
  int count = FPDFText_CountChars(text_page);
  char *out = (char *)calloc((size_t)count + 1, 1);
  unsigned short *wide = (unsigned short *)calloc((size_t)count + 1, sizeof(unsigned short));
  if (!out || !wide) {
    free(out);
    free(wide);
    FPDFText_ClosePage(text_page);
    return NULL;
  }
  int got = FPDFText_GetText(text_page, 0, count, wide); /* includes the terminating NUL */
  for (int i = 0; i < got - 1 && i < count; i++) {
    out[i] = wide[i] < 128 ? (char)wide[i] : '?';
  }
  free(wide);
  FPDFText_ClosePage(text_page);
  return out;
}

static int check(int ok, const char *what) {
  printf("smoke: %s %s\n", what, ok ? "ok" : "FAILED");
  return ok ? 0 : 1;
}

#ifdef SMOKE_EPDF
typedef struct {
  FPDF_FILEWRITE base; /* must stay the first member */
  unsigned char *data;
  size_t len;
  size_t cap;
} MemWriter;

static int write_block(FPDF_FILEWRITE *self, const void *data, unsigned long size) {
  MemWriter *w = (MemWriter *)self;
  if (w->len + size > w->cap) {
    size_t cap = w->cap ? w->cap : 4096;
    while (cap < w->len + size) cap *= 2;
    unsigned char *grown = (unsigned char *)realloc(w->data, cap);
    if (!grown) return 0;
    w->data = grown;
    w->cap = cap;
  }
  memcpy(w->data + w->len, data, size);
  w->len += size;
  return 1;
}

/* Box (page coordinates, points) around the first match of NEEDLE on the page, padded by 1 point. */
static int needle_box(FPDF_PAGE page, const char *needle, FS_RECTF *box) {
  size_t len = strlen(needle);
  if (len == 0 || len > 200) return 0;
  FPDF_TEXTPAGE text_page = FPDFText_LoadPage(page);
  if (!text_page) return 0;
  unsigned short wide[256];
  for (size_t i = 0; i < len; i++) wide[i] = (unsigned char)needle[i];
  wide[len] = 0;
  int found = 0;
  FPDF_SCHHANDLE handle = FPDFText_FindStart(text_page, wide, 0, 0);
  if (handle) {
    if (FPDFText_FindNext(handle)) {
      int start = FPDFText_GetSchResultIndex(handle);
      int count = FPDFText_GetSchCount(handle);
      double left = 1e9, right = -1e9, bottom = 1e9, top = -1e9;
      for (int i = start; i < start + count; i++) {
        double l, r, b, t;
        if (!FPDFText_GetCharBox(text_page, i, &l, &r, &b, &t)) continue;
        if (l < left) left = l;
        if (r > right) right = r;
        if (b < bottom) bottom = b;
        if (t > top) top = t;
      }
      if (right > left && top > bottom) {
        box->left = (float)(left - 1.0);
        box->right = (float)(right + 1.0);
        box->bottom = (float)(bottom - 1.0);
        box->top = (float)(top + 1.0);
        found = 1;
      }
    }
    FPDFText_FindClose(handle);
  }
  FPDFText_ClosePage(text_page);
  return found;
}

static int redaction_check(FPDF_DOCUMENT doc, const char *needle, const char *keep, int skip_apply) {
  int failures = 0;
  FPDF_PAGE page = FPDF_LoadPage(doc, 0);
  if (!page) return check(0, "redaction: load page 0");
  FS_RECTF box;
  if (!needle_box(page, needle, &box)) {
    FPDF_ClosePage(page);
    return check(0, "redaction: locate text to redact");
  }
  FPDF_ANNOTATION annot = FPDFPage_CreateAnnot(page, FPDF_ANNOT_REDACT);
  failures += check(annot != NULL, "redaction: create redact annotation");
  if (!annot) {
    FPDF_ClosePage(page);
    return failures;
  }
  failures += check(FPDFAnnot_SetRect(annot, &box) != 0, "redaction: set annotation rectangle");
  FPDFPage_CloseAnnot(annot);

  if (!skip_apply) {
    uint32_t removed = 0;
    failures += check(EPDFPage_ApplyRedactions(page, NULL, 0, &removed) != 0, "redaction: EPDFPage_ApplyRedactions");
  } else {
    printf("smoke: redaction: apply skipped on request\n");
  }
  failures += check(FPDFPage_GenerateContent(page) != 0, "redaction: generate content");
  FPDF_ClosePage(page);

  MemWriter writer;
  memset(&writer, 0, sizeof(writer));
  writer.base.version = 1;
  writer.base.WriteBlock = write_block;
  failures += check(FPDF_SaveAsCopy(doc, &writer.base, FPDF_NO_INCREMENTAL) != 0, "redaction: full-rewrite save");
  if (writer.len == 0 || writer.len > 2000000000u) {
    free(writer.data);
    return failures + check(0, "redaction: saved bytes");
  }

  FPDF_DOCUMENT saved = FPDF_LoadMemDocument(writer.data, (int)writer.len, NULL);
  failures += check(saved != NULL, "redaction: reopen saved copy");
  if (saved) {
    FPDF_PAGE saved_page = FPDF_LoadPage(saved, 0);
    char *text = saved_page ? page_text(saved_page) : NULL;
    failures += check(text != NULL, "redaction: extract text from saved copy");
    if (text) {
      failures += check(strstr(text, needle) == NULL, "redaction: redacted text is gone from the saved copy");
      failures += check(strstr(text, keep) != NULL, "redaction: untouched text is still there");
      free(text);
    }
    if (saved_page) FPDF_ClosePage(saved_page);
    FPDF_CloseDocument(saved);
  }
  free(writer.data);
  return failures;
}
#endif /* SMOKE_EPDF */

int main(int argc, char **argv) {
  const char *path = NULL, *contains = NULL, *redact = NULL, *keep = NULL;
  int pages = -1, skip_apply = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--pages") == 0 && i + 1 < argc) {
      pages = atoi(argv[++i]);
    } else if (strcmp(argv[i], "--contains") == 0 && i + 1 < argc) {
      contains = argv[++i];
    } else if (strcmp(argv[i], "--redact") == 0 && i + 1 < argc) {
      redact = argv[++i];
    } else if (strcmp(argv[i], "--keep") == 0 && i + 1 < argc) {
      keep = argv[++i];
    } else if (strcmp(argv[i], "--skip-apply") == 0) {
      skip_apply = 1;
    } else if (!path && argv[i][0] != '-') {
      path = argv[i];
    } else {
      path = NULL;
      break;
    }
  }
  if (!path || pages < 0 || !contains || (redact && !keep)) {
    fprintf(stderr, "usage: smoke <file.pdf> --pages N --contains TEXT [--redact NEEDLE --keep TEXT [--skip-apply]]\n");
    return 2;
  }
#ifndef SMOKE_EPDF
  if (redact) {
    fprintf(stderr, "smoke: this binary was built without the EmbedPDF extensions (-DSMOKE_EPDF=1)\n");
    return 2;
  }
#endif

  FPDF_LIBRARY_CONFIG config;
  memset(&config, 0, sizeof(config));
  config.version = 2;
  FPDF_InitLibraryWithConfig(&config);
  (void)skip_apply; /* only used with -DSMOKE_EPDF=1 */

  int failures = 0;

  /* Error mapping: a missing file must report FPDF_ERR_FILE. */
  FPDF_DOCUMENT missing = FPDF_LoadDocument("/nonexistent/smoke-missing.pdf", NULL);
  failures += check(missing == NULL && FPDF_GetLastError() == FPDF_ERR_FILE, "missing file reports FPDF_ERR_FILE");

  FPDF_DOCUMENT doc = FPDF_LoadDocument(path, NULL);
  failures += check(doc != NULL, "open fixture");
  if (doc) {
    failures += check(FPDF_GetPageCount(doc) == pages, "page count");
    FPDF_PAGE page = FPDF_LoadPage(doc, 0);
    char *text = page ? page_text(page) : NULL;
    failures += check(text != NULL && strstr(text, contains) != NULL, "text extraction");
    free(text);
    if (page) FPDF_ClosePage(page);
#ifdef SMOKE_EPDF
    if (redact) failures += redaction_check(doc, redact, keep, skip_apply);
#endif
    FPDF_CloseDocument(doc);
  }

  FPDF_DestroyLibrary();
  if (failures) {
    printf("smoke: %d check(s) failed\n", failures);
    return 1;
  }
  printf("smoke: all checks passed\n");
  return 0;
}
