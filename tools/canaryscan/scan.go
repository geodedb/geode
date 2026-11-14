package main

import (
	"bufio"
	"encoding/csv"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var canaryRe = regexp.MustCompile(`^\s*(?://|#|--)\s*CANARY:\s*(.*)$`)
var kvRe = regexp.MustCompile(`\s*([^=;\s]+)\s*=\s*([^;]+)\s*`)

// directories to skip during scan
var skipDirs = map[string]bool{
    ".git": true, "node_modules": true, "vendor": true, "bin": true, "zig-out": true, ".zig-cache": true,
    ".crush": true, "data": true, "certs": true, "zig-packages": true, "zig-pkg": true, ".worktrees": true,
}

// marker is one CANARY line: where it is and what it says. file is relative
// to the scan root, with forward slashes.
type marker struct {
    id, feature, aspect, status, owner, updated string
    file                                        string
    line                                        int
    tests, benches                              []string
}

// srcPos orders markers by where they are in the tree.
type srcPos struct {
    file string
    line int
}

func (a srcPos) less(b srcPos) bool {
    if a.file != b.file {
        return a.file < b.file
    }
    return a.line < b.line
}

func Scan(root string) (report, error) {
    markers, err := collect(root)
    if err != nil {
        return report{}, err
    }
    return aggregate(markers), nil
}

// collect walks root and returns every marker. SONNY-6531: a file is named
// relative to root, so the output does not depend on how --root is spelled
// (`.`, `./`, an absolute path, `../..` from a hook).
func collect(root string) ([]marker, error) {
    var markers []marker
    err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
        if err != nil {
            return err
        }
        if d.IsDir() {
            if skipDirs[filepath.Base(path)] {
                return filepath.SkipDir
            }
            return nil
        }
        // only scan likely text files (simple heuristic)
        if isBinary(path) {
            return nil
        }
        rel, err := filepath.Rel(root, path)
        if err != nil {
            return err
        }
        rel = filepath.ToSlash(rel)
        f, err := os.Open(path)
        if err != nil {
            return nil // skip unreadable files
        }
        defer f.Close()
        sc := bufio.NewScanner(f)
        ln := 0
        for sc.Scan() {
            ln++
            line := sc.Text()
            m := canaryRe.FindStringSubmatch(line)
            if len(m) < 2 {
                continue
            }
            rec, err := parseCanaryKV(m[1])
            if err != nil {
                return fmt.Errorf("parse %s:%d: %w", path, ln, err)
            }
            mk := marker{
                id:      rec["REQ"],
                feature: unquote(rec["FEATURE"]),
                aspect:  rec["ASPECT"],
                status:  rec["STATUS"],
                owner:   rec["OWNER"],
                updated: rec["UPDATED"],
                file:    rel,
                line:    ln,
                tests:   splitList(rec["TEST"]),
                benches: splitList(rec["BENCH"]),
            }
            if mk.id == "" || mk.aspect == "" || mk.status == "" {
                return fmt.Errorf("missing required fields in %s:%d", path, ln)
            }
            markers = append(markers, mk)
        }
        return nil
    })
    if err != nil {
        return nil, err
    }
    return markers, nil
}

// aggregate shapes the report. Its output depends only on the set of
// markers, not on the order they were found in.
func aggregate(markers []marker) report {
    type key struct {
        id, feature, aspect, status, owner, updated string
    }
    type val struct {
        files   map[string]struct{}
        tests   map[string]struct{}
        benches map[string]struct{}
        first   srcPos
    }
    agg := map[key]*val{}

    for _, mk := range markers {
        k := key{
            id:      mk.id,
            feature: mk.feature,
            aspect:  mk.aspect,
            status:  mk.status,
            owner:   mk.owner,
            updated: mk.updated,
        }
        pos := srcPos{file: mk.file, line: mk.line}
        v, ok := agg[k]
        if !ok {
            v = &val{
                files:   map[string]struct{}{},
                tests:   map[string]struct{}{},
                benches: map[string]struct{}{},
                first:   pos,
            }
            agg[k] = v
        } else if pos.less(v.first) {
            v.first = pos
        }
        v.files[mk.file] = struct{}{}
        for _, t := range mk.tests {
            if t != "" {
                v.tests[t] = struct{}{}
            }
        }
        for _, b := range mk.benches {
            if b != "" {
                v.benches[b] = struct{}{}
            }
        }
    }

    // shape report
    reqMap := map[string][]featureEntry{}
    sumStatus := map[string]int{}
    sumAspect := map[string]int{}

    for k, v := range agg {
        // Auto-promotion: if status is IMPL and at least one test present -> TESTED
        // If at least one bench present and status IMPL or TESTED -> BENCHED (bench is stronger evidence)
        promoted_status := k.status
        if promoted_status == "IMPL" && len(v.tests) > 0 {
            promoted_status = "TESTED"
        }
        if (promoted_status == "IMPL" || promoted_status == "TESTED") && len(v.benches) > 0 {
            promoted_status = "BENCHED"
        }
        ent := featureEntry{
            Feature: k.feature,
            Aspect:  k.aspect,
            Status:  promoted_status,
            Files:   keys(v.files),
            Tests:   keys(v.tests),
            Benches: keys(v.benches),
            Owner:   k.owner,
            Updated: k.updated,
            first:   v.first,
        }
        reqMap[normalizeReq(k.id)] = append(reqMap[normalizeReq(k.id)], ent)
        sumStatus[ent.Status]++
        sumAspect[k.aspect]++
    }
    var rows []requirementRow
    for id, feats := range reqMap {
        // SONNY-6374: a total order. SONNY-6531: by source position first
        // (the entry's first marker: file, then line), so a FEATURE, STATUS,
        // OWNER or UPDATED edit does not move rows inside the requirement;
        // the remaining fields break the tie of two entries whose first
        // markers share a line (one raw ID written with two hyphens).
        sort.Slice(feats, func(i, j int) bool {
            a, b := feats[i], feats[j]
            if a.first != b.first {
                return a.first.less(b.first)
            }
            if a.Feature != b.Feature {
                return a.Feature < b.Feature
            }
            if a.Aspect != b.Aspect {
                return a.Aspect < b.Aspect
            }
            if a.Status != b.Status {
                return a.Status < b.Status
            }
            if a.Owner != b.Owner {
                return a.Owner < b.Owner
            }
            if a.Updated != b.Updated {
                return a.Updated < b.Updated
            }
            if x, y := strings.Join(a.Files, "\n"), strings.Join(b.Files, "\n"); x != y {
                return x < y
            }
            if x, y := strings.Join(a.Tests, "\n"), strings.Join(b.Tests, "\n"); x != y {
                return x < y
            }
            return strings.Join(a.Benches, "\n") < strings.Join(b.Benches, "\n")
        })
        rows = append(rows, requirementRow{ID: id, Features: feats})
    }
    sort.Slice(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
    return report{
        Requirements: rows,
        Summary: summary{
            ByStatus: sumStatus,
            ByAspect: sumAspect,
        },
    }
}

func parseCanaryKV(s string) (map[string]string, error) {
    out := map[string]string{}
    for _, seg := range strings.Split(s, ";") {
        seg = strings.TrimSpace(seg)
        if seg == "" {
            continue
        }
        m := kvRe.FindStringSubmatch(seg)
        if len(m) != 3 {
            return nil, fmt.Errorf("bad kv segment %q", seg)
        }
        key := strings.ToUpper(strings.TrimSpace(m[1]))
        val := strings.TrimSpace(m[2])
        out[key] = strings.TrimSpace(val)
    }
    // Validate enums (best‑effort)
    // Valid statuses: STUB, IMPL, TESTED, BENCHED, COMPLETE, EXEMPT, MISSING, REMOVED
    status := strings.ToUpper(out["STATUS"])
    switch status {
    case "MISSING", "STUB", "IMPL", "TESTED", "BENCHED", "COMPLETE", "EXEMPT", "REMOVED":
    default:
        if status != "" {
            return nil, fmt.Errorf("invalid STATUS %q", status)
        }
    }
    return out, nil
}

func unquote(v string) string {
    v = strings.TrimSpace(v)
    if len(v) >= 2 && ((v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'')) {
        return v[1 : len(v)-1]
    }
    return v
}

func splitList(v string) []string {
    v = strings.TrimSpace(v)
    if v == "" {
        return nil
    }
    // allow comma or space
    parts := strings.FieldsFunc(v, func(r rune) bool { return r == ',' })
    var out []string
    for _, p := range parts {
        p = strings.TrimSpace(p)
        if p != "" {
            out = append(out, p)
        }
    }
    return out
}

func keys(m map[string]struct{}) []string {
    out := make([]string, 0, len(m))
    for k := range m {
        out = append(out, k)
    }
    sort.Strings(out)
    return out
}

func isBinary(path string) bool {
    ext := strings.ToLower(filepath.Ext(path))
    switch ext {
    case ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".gz", ".tgz", ".jar", ".wasm",
         ".exe", ".dll", ".so", ".dylib", ".db", ".db-wal", ".db-shm", ".csv", ".md":
        return true
    }
    // Skip files with no extension that look binary
    if ext == "" && strings.Contains(path, "zig-out") {
        return true
    }
    return false
}

// CheckStaleness: fail if any TESTED/BENCHED has UPDATED older than dur
func CheckStaleness(rep report, dur time.Duration) error {
    cut := time.Now().UTC().Add(-dur)
    var errs []string
    for _, r := range rep.Requirements {
        for _, f := range r.Features {
            if f.Status == "TESTED" || f.Status == "BENCHED" {
                if f.Updated == "" {
                    errs = append(errs, fmt.Sprintf("%s %s missing UPDATED", r.ID, f.Feature))
                    continue
                }
                t, err := time.Parse("2006-01-02", f.Updated)
                if err != nil || t.Before(time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC)) {
                    errs = append(errs, fmt.Sprintf("%s %s bad UPDATED=%q", r.ID, f.Feature, f.Updated))
                    continue
                }
                if t.Before(cut) {
                    errs = append(errs, fmt.Sprintf("REQ=%s feature=%s UPDATED=%s > %dd", r.ID, f.Feature, f.Updated, int(dur.Hours()/24)))
                }
            }
        }
    }
    if len(errs) > 0 {
        return errors.New(strings.Join(errs, "; "))
    }
    return nil
}

func WriteCSV(rep report, path string) error {
    f, err := os.Create(path)
    if err != nil {
        return err
    }
    defer f.Close()
    w := csv.NewWriter(f)
    defer w.Flush()
    _ = w.Write([]string{"req", "feature", "aspect", "status", "file", "test", "bench", "owner", "updated"})
    for _, r := range rep.Requirements {
        for _, f := range r.Features {
            rowBase := []string{r.ID, f.Feature, f.Aspect, f.Status, "", "", "", f.Owner, f.Updated}
            // explode files/tests/benches (max(len))
            max := max3(len(f.Files), len(f.Tests), len(f.Benches))
            for i := 0; i < max; i++ {
                row := make([]string, len(rowBase))
                copy(row, rowBase)
                if i < len(f.Files) {
                    row[4] = f.Files[i]
                }
                if i < len(f.Tests) {
                    row[5] = f.Tests[i]
                }
                if i < len(f.Benches) {
                    row[6] = f.Benches[i]
                }
                if err := w.Write(row); err != nil {
                    return err
                }
            }
            if max == 0 {
                if err := w.Write(rowBase); err != nil {
                    return err
                }
            }
        }
    }
    return nil
}

func max3(a, b, c int) int {
    if a < b {
        a = b
    }
    if a < c {
        a = c
    }
    return a
}

func normalizeReq(id string) string {
    id = strings.TrimSpace(id)
    id = strings.ReplaceAll(id, "‑", "-") // NB hyphen -> ASCII
    id = strings.ReplaceAll(id, "–", "-")
    return id
}
