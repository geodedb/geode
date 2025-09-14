package gql

type Error struct {
	StatusClass string
	Code string
	Message string
	Anchor string
	Additional []string
	FlaggerFindings []string
}

func (e *Error) Error() string { return e.Code+": "+e.Message }

var (
	ErrUS001 = &Error{Code: "US001"}
	ErrIllegalOrderKey = &Error{Code: "IllegalOrderKey"}
	ErrTypeMismatch = &Error{Code: "TypeMismatch"}
)
