/* Dear ImGui's IM_ASSERT, routed to viewSEG's log in release builds instead of
   aborting (asserts.nim force-includes this header into every C++ file). */
#ifndef VIEWSEG_IMASSERT_H
#define VIEWSEG_IMASSERT_H
#ifdef __cplusplus
extern "C" void viewsegImAssert(const char* expr, const char* file, int line);
#define IM_ASSERT(_EXPR) ((_EXPR) ? (void)0 : viewsegImAssert(#_EXPR, __FILE__, __LINE__))
#endif
#endif
