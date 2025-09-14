Go GQL Client — native graph values for Geode

- Package: geode/clients/go/gql
- Purpose: Provide a GQL-specific client with native typed values and simple DB/Conn/Query API

Quick start

package main

import (
	"context"
	"fmt"
	"geode/clients/go/gql"
)

func main() {
	db, _ := gql.Open("process:./zig-out/bin/geoded?page_size=1000")
	conn, _ := db.Connect(context.Background())
	defer conn.Close()
	first, next, err := conn.Query(context.Background(), "RETURN 1 AS x ORDER BY x LIMIT 1", nil, 100)
	if err != nil { panic(err) }
	for _, r := range first.Rows {
		fmt.Println(r["x"].Int)
	}
	for {
		page, err := next(context.Background())
		if err != nil { break }
		for _, r := range page.Rows { fmt.Println(r["x"].Int) }
	}
}

Notes

- Values are mapped to gql.Value with Kind {Null,Int,Bool,Str,Dec}; DECIMAL uses big.Rat.
- ORDER metadata (Ordered, OrderKeys) is preserved on each Page.
- PROFILE statements return an empty result set with Final=true.
