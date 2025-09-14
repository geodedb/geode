package gql

import (
	"testing"
)

var tcpOnce struct{
	started bool
}

func TestMain(m *testing.M) {
	m.Run()
}
