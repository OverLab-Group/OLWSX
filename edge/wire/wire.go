package wire

// Hint bitfield used by edge to inform Actor Manager/Core.
const (
	HintRateLimited uint32 = 0x1
	HintWAFBlocked  uint32 = 0x2
	HintChallenged  uint32 = 0x4
)

// Envelope binary layout (length-prefixed slices). Edge serializes requests to Actor Manager:
// [len(method)][method][len(path)][path][len(headers)][headers][len(body)][body][traceID][spanID][hints]