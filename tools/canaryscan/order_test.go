package main

import (
	"bytes"
	"encoding/json"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SONNY-6531 item 3: status.csv / status.json must be a function of the
// markers alone. Rows of one requirement are ordered by where they are in the
// source (file, then line, then the remaining fields), and a file is named
// relative to --root, so the output does not depend on the order files are
// visited in, on how --root is spelled, or on FEATURE/STATUS/OWNER/UPDATED
// edits elsewhere in the requirement.

// orderFixture writes markers for REQ-ORDER-6531 spread over two files, in
// an order where FEATURE text sorts against source position, plus ties that
// share FEATURE and ASPECT.
func orderFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "src", "b"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	mustWrite(t, filepath.Join(dir, "src", "a.zig"), strings.Join([]string{
		`// CANARY: REQ=REQ-ORDER-6531; FEATURE="Zeta"; ASPECT=First; STATUS=TESTED; TEST=t1; OWNER=o; UPDATED=2026-11-14`,
		`const x = 1;`,
		`// CANARY: REQ=REQ-ORDER-6531; FEATURE="Alpha"; ASPECT=Second; STATUS=IMPL; OWNER=o; UPDATED=2026-11-14`,
		`// CANARY: REQ=REQ-OTHER-6531; FEATURE="Other"; ASPECT=A; STATUS=STUB; OWNER=o; UPDATED=2026-11-14`,
		`// CANARY: REQ=REQ-ORDER-6531; FEATURE="Mid"; ASPECT=Tie; STATUS=IMPL; OWNER=b; UPDATED=2026-11-14`,
		`// CANARY: REQ=REQ-ORDER-6531; FEATURE="Mid"; ASPECT=Tie; STATUS=IMPL; OWNER=a; UPDATED=2026-11-14`,
		``,
	}, "\n"))
	mustWrite(t, filepath.Join(dir, "src", "b", "c.zig"), strings.Join([]string{
		`// CANARY: REQ=REQ-ORDER-6531; FEATURE="Beta"; ASPECT=Third; STATUS=EXEMPT; OWNER=o; UPDATED=2026-11-14`,
		`// CANARY: REQ=REQ-ORDER-6531; FEATURE="Alpha"; ASPECT=Second; STATUS=IMPL; OWNER=o; UPDATED=2026-11-14`,
		``,
	}, "\n"))
	return dir
}

// render returns the CSV and JSON bytes for rep, with the timestamp fixed.
func render(t *testing.T, rep report) (string, string) {
	t.Helper()
	out := filepath.Join(t.TempDir(), "status.csv")
	if err := WriteCSV(rep, out); err != nil {
		t.Fatalf("write csv: %v", err)
	}
	c, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read csv: %v", err)
	}
	var j bytes.Buffer
	enc := json.NewEncoder(&j)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(rep); err != nil {
		t.Fatalf("encode json: %v", err)
	}
	return string(c), j.String()
}

func TestScanSameTreeTwiceIsByteIdentical(t *testing.T) {
	dir := orderFixture(t)
	var firstCSV, firstJSON string
	for i := 0; i < 20; i++ {
		rep, err := Scan(dir)
		if err != nil {
			t.Fatalf("scan: %v", err)
		}
		c, j := render(t, rep)
		if i == 0 {
			firstCSV, firstJSON = c, j
			continue
		}
		if c != firstCSV || j != firstJSON {
			t.Fatalf("scan %d differs:\n%s\nfirst:\n%s", i, c, firstCSV)
		}
	}
}

func TestRowsOfOneRequirementFollowSourcePosition(t *testing.T) {
	rep, err := Scan(orderFixture(t))
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	c, _ := render(t, rep)
	want := strings.Join([]string{
		"req,feature,aspect,status,file,test,bench,owner,updated",
		"REQ-ORDER-6531,Zeta,First,TESTED,src/a.zig,t1,,o,2026-11-14",
		// Alpha/Second is in src/a.zig:3 and src/b/c.zig:2; it sorts by its
		// first position.
		"REQ-ORDER-6531,Alpha,Second,IMPL,src/a.zig,,,o,2026-11-14",
		"REQ-ORDER-6531,Alpha,Second,IMPL,src/b/c.zig,,,o,2026-11-14",
		"REQ-ORDER-6531,Mid,Tie,IMPL,src/a.zig,,,b,2026-11-14",
		"REQ-ORDER-6531,Mid,Tie,IMPL,src/a.zig,,,a,2026-11-14",
		"REQ-ORDER-6531,Beta,Third,EXEMPT,src/b/c.zig,,,o,2026-11-14",
		"REQ-OTHER-6531,Other,A,STUB,src/a.zig,,,o,2026-11-14",
		"",
	}, "\n")
	if c != want {
		t.Fatalf("status.csv rows are not in (ID, file, line) order:\n%s\nwant:\n%s", c, want)
	}
}

func TestScanOutputDoesNotDependOnHowRootIsSpelled(t *testing.T) {
	dir := orderFixture(t)
	abs, err := Scan(dir)
	if err != nil {
		t.Fatalf("scan abs: %v", err)
	}
	absCSV, absJSON := render(t, abs)

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(filepath.Dir(dir)); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	defer os.Chdir(wd)
	for _, root := range []string{filepath.Base(dir), "./" + filepath.Base(dir) + "/"} {
		rel, err := Scan(root)
		if err != nil {
			t.Fatalf("scan %s: %v", root, err)
		}
		relCSV, relJSON := render(t, rel)
		if relCSV != absCSV || relJSON != absJSON {
			t.Fatalf("--root %q wrote:\n%s\n--root %q wrote:\n%s", root, relCSV, dir, absCSV)
		}
	}
}

func TestReportDoesNotDependOnVisitOrder(t *testing.T) {
	markers, err := collect(orderFixture(t))
	if err != nil {
		t.Fatalf("collect: %v", err)
	}
	wantCSV, wantJSON := render(t, aggregate(markers))
	rng := rand.New(rand.NewPCG(6531, 1))
	for i := 0; i < 50; i++ {
		shuffled := append([]marker(nil), markers...)
		rng.Shuffle(len(shuffled), func(a, b int) { shuffled[a], shuffled[b] = shuffled[b], shuffled[a] })
		c, j := render(t, aggregate(shuffled))
		if c != wantCSV || j != wantJSON {
			t.Fatalf("visit order %d wrote:\n%s\nwant:\n%s", i, c, wantCSV)
		}
	}
}
