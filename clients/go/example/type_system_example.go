package main

import (
	"context"
	"fmt"
	"log"

	gql "go.spyder.org/geode/clients/go/gql"
)

// TypeSystemExample demonstrates the extended type system features
// Run this as a separate program or call from main()
func TypeSystemExample() {
	// Connect with QUIC (v0.18.0 default)
	db, err := gql.Open("quic://127.0.0.1:8443")
	if err != nil {
		log.Fatal(err)
	}
	
	ctx := context.Background()
	conn, err := db.Connect(ctx)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	
	fmt.Println("=== Geode Extended Type System Examples ===")
	
	// 1. Network Types
	fmt.Println("\n1. Network Types (IP, CIDR, MAC):")
	
	// Create network devices
	_, _, err = conn.Query(ctx, `
		CREATE (d:Device {
			hostname: "router-01",
			ip_address: IpAddr("192.168.1.1"),
			subnet: Subnet("192.168.0.0/16"),
			mac_address: Mac("aa:bb:cc:dd:ee:ff")
		})
	`, nil, 100)
	
	if err == nil {
		fmt.Println("   ✓ Created device with network types")
	}
	
	// Query IP containment
	page, _, err := conn.Query(ctx, `
		MATCH (d:Device)
		WHERE ip_contains(Subnet("192.168.0.0/16"), d.ip_address)
		RETURN d.hostname, d.ip_address, ip_is_private(d.ip_address) AS is_private
	`, nil, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ Devices in subnet 192.168.0.0/16:")
		for _, row := range page.Rows {
			fmt.Printf("     - %s: %s (private: %v)\n", 
				row["d.hostname"].Str, 
				row["d.ip_address"].Str,
				row["is_private"].Bool)
		}
	}
	
	// 2. Geographic Types
	fmt.Println("\n2. Geographic Types (LatLon, Geometry):")
	
	// Create locations
	_, _, err = conn.Query(ctx, `
		CREATE (l1:Location {
			name: "San Francisco",
			coordinates: LatLon(37.7749, -122.4194),
			service_area: GeometryFromText("POLYGON((-122.5 37.7, -122.5 37.8, -122.3 37.8, -122.3 37.7, -122.5 37.7))")
		})
	`, nil, 100)
	
	_, _, err = conn.Query(ctx, `
		CREATE (l2:Location {
			name: "Oakland",
			coordinates: LatLon(37.8044, -122.2712)
		})
	`, nil, 100)
	
	if err == nil {
		fmt.Println("   ✓ Created locations with geographic data")
	}
	
	// Calculate distances
	page, _, err = conn.Query(ctx, `
		MATCH (l1:Location {name: "San Francisco"})
		MATCH (l2:Location {name: "Oakland"})
		RETURN distance_haversine(l1.coordinates, l2.coordinates) AS distance_m
	`, nil, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Printf("   ✓ Distance SF to Oakland: %d meters\n", page.Rows[0]["distance_m"].Int)
	}
	
	// Spatial queries
	page, _, err = conn.Query(ctx, `
		MATCH (l:Location)
		WHERE st_intersects(
			l.service_area,
			GeometryFromText("POINT(-122.4 37.75)")
		)
		RETURN l.name
	`, nil, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ Locations with service area containing point:")
		for _, row := range page.Rows {
			fmt.Printf("     - %s\n", row["l.name"].Str)
		}
	}
	
	// 3. Vector Types (Embeddings)
	fmt.Println("\n3. Vector Types (Embeddings, Similarity):")
	
	// Create documents with embeddings
	_, _, err = conn.Query(ctx, `
		CREATE (d1:Document {
			title: "Introduction to Graph Databases",
			embedding: Vector([0.1, 0.2, 0.3, 0.4, 0.5])
		})
	`, nil, 100)
	
	_, _, err = conn.Query(ctx, `
		CREATE (d2:Document {
			title: "Advanced Graph Algorithms",
			embedding: Vector([0.15, 0.25, 0.28, 0.35, 0.45])
		})
	`, nil, 100)
	
	_, _, err = conn.Query(ctx, `
		CREATE (d3:Document {
			title: "Machine Learning Basics",
			embedding: Vector([0.8, 0.7, 0.6, 0.5, 0.4])
		})
	`, nil, 100)
	
	if err == nil {
		fmt.Println("   ✓ Created documents with vector embeddings")
	}
	
	// Vector similarity search
	queryVector := map[string]interface{}{
		"query_vec": []float32{0.12, 0.22, 0.32, 0.38, 0.48},
	}
	
	page, _, err = conn.Query(ctx, `
		MATCH (d:Document)
		WITH d, vector_cosine(d.embedding, $query_vec) AS similarity
		WHERE similarity > 0.8
		RETURN d.title, similarity
		ORDER BY similarity DESC
		LIMIT 5
	`, queryVector, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ Similar documents (cosine > 0.8):")
		for _, row := range page.Rows {
			sim, _ := row["similarity"].Dec.Float64()
			fmt.Printf("     - %s (similarity: %.3f)\n",
				row["d.title"].Str,
				sim)
		}
	}
	
	// K-NN search
	page, _, err = conn.Query(ctx, `
		MATCH (d:Document)
		WITH vector_knn("embedding", $query_vec, 2, "cosine") AS neighbors
		UNWIND neighbors AS neighbor
		MATCH (similar:Document {id: neighbor.id})
		RETURN similar.title, neighbor.score
		ORDER BY neighbor.score DESC
	`, queryVector, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ Top 2 nearest neighbors:")
		for _, row := range page.Rows {
			score, _ := row["neighbor.score"].Dec.Float64()
			fmt.Printf("     - %s (score: %.3f)\n",
				row["similar.title"].Str,
				score)
		}
	}
	
	// 4. Security Types
	fmt.Println("\n4. Security Types (Hash):")
	
	// Store secure hashes
	_, _, err = conn.Query(ctx, `
		CREATE (u:User {
			username: "alice",
			password_hash: Hash("SHA3-256", "3a985da74fe225b2045c172d6bd390bd855f086e5f6ee8a2d4a8a24ab9f87612")
		})
	`, nil, 100)
	
	if err == nil {
		fmt.Println("   ✓ Created user with secure hash")
	}
	
	// Verify hash (constant-time comparison)
	verifyParams := map[string]interface{}{
		"provided_hash": "SHA3-256:3a985da74fe225b2045c172d6bd390bd855f086e5f6ee8a2d4a8a24ab9f87612",
	}
	
	page, _, err = conn.Query(ctx, `
		MATCH (u:User {username: "alice"})
		WHERE hash_equals(u.password_hash, Hash("SHA3-256", $provided_hash))
		RETURN u.username, hash_alg(u.password_hash) AS algorithm
	`, verifyParams, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Printf("   ✓ Hash verified for user: %s (algorithm: %s)\n",
			page.Rows[0]["u.username"].Str,
			page.Rows[0]["algorithm"].Str)
	}
	
	// 5. Financial Types
	fmt.Println("\n5. Financial Types (Currency):")
	
	// Multi-currency transactions
	_, _, err = conn.Query(ctx, `
		CREATE (t:Transaction {
			id: "TXN-001",
			amount: 1234.56,
			currency: Currency("USD"),
			description: "International wire transfer"
		})
	`, nil, 100)
	
	page, _, err = conn.Query(ctx, `
		MATCH (t:Transaction)
		RETURN t.id, t.amount, t.currency, 
		       minor_units(t.currency) AS decimals,
		       t.amount * POWER(10, minor_units(t.currency)) AS amount_in_cents
	`, nil, 100)
	
	if err == nil && len(page.Rows) > 0 {
		row := page.Rows[0]
		amount, _ := row["t.amount"].Dec.Float64()
		fmt.Printf("   ✓ Transaction %s: %.2f %s (%d decimal places, %d cents)\n",
			row["t.id"].Str,
			amount,
			row["t.currency"].Str,
			row["decimals"].Int,
			row["amount_in_cents"].Int)
	}
	
	// 6. Internationalization Types
	fmt.Println("\n6. Internationalization (LanguageTag):")
	
	// Content localization
	_, _, err = conn.Query(ctx, `
		CREATE (c:Content {
			title: "User Guide",
			language: lang_canonicalize("EN-us"),
			available_languages: [
				LanguageTag("fr-FR"),
				LanguageTag("de-DE"),
				LanguageTag("ja-JP")
			]
		})
	`, nil, 100)
	
	// Language matching
	langParams := map[string]interface{}{
		"user_langs": []string{"en-US", "en"},
	}
	
	page, _, err = conn.Query(ctx, `
		MATCH (c:Content)
		WHERE lang_match($user_langs, c.language)
		RETURN c.title, c.language
	`, langParams, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ Content matching user language preferences:")
		for _, row := range page.Rows {
			fmt.Printf("     - %s (language: %s)\n",
				row["c.title"].Str,
				row["c.language"].Str)
		}
	}
	
	// 7. Scientific Types
	fmt.Println("\n7. Scientific Types (Temperature, Pressure):")
	
	// Weather station readings
	_, _, err = conn.Query(ctx, `
		CREATE (r:Reading {
			station_id: "WS-001",
			timestamp: timestamp(),
			temperature: Temperature(23.5, "C"),
			pressure: Pressure(1013.25, "hPa")
		})
	`, nil, 100)
	
	page, _, err = conn.Query(ctx, `
		MATCH (r:Reading)
		WHERE r.temperature > Temperature(20, "C")
		RETURN r.station_id, r.temperature, r.pressure
	`, nil, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ Weather readings above 20°C:")
		for _, row := range page.Rows {
			fmt.Printf("     - Station %s: %v, %v\n",
				row["r.station_id"].Str,
				row["r.temperature"].Str,
				row["r.pressure"].Str)
		}
	}
	
	// 8. Combined Example - IoT Device Monitoring
	fmt.Println("\n8. Combined Example - IoT Device Monitoring:")
	
	// Create IoT sensor with multiple type properties
	_, _, err = conn.Query(ctx, `
		CREATE (sensor:IoTSensor {
			device_id: "IOT-001",
			ip_address: IpAddr("192.168.1.100"),
			mac_address: Mac("aa:bb:cc:dd:ee:ff"),
			location: LatLon(37.7749, -122.4194),
			last_reading: Temperature(22.5, "C")
		})
	`, nil, 100)
	
	// Complex query using multiple types
	page, _, err = conn.Query(ctx, `
		MATCH (s:IoTSensor)
		WHERE ip_contains(Subnet("192.168.0.0/16"), s.ip_address)
		  AND distance_haversine(s.location, LatLon(37.7749, -122.4194)) < 10000
		  AND NOT mac_is_multicast(s.mac_address)
		RETURN s.device_id, s.ip_address, s.location, s.last_reading
	`, nil, 100)
	
	if err == nil && len(page.Rows) > 0 {
		fmt.Println("   ✓ IoT sensors in local network within 10km:")
		for _, row := range page.Rows {
			fmt.Printf("     - Device %s at %s (location: %v, temp: %v)\n",
				row["s.device_id"].Str,
				row["s.ip_address"].Str,
				row["s.location"].Str,
				row["s.last_reading"].Str)
		}
	}
	
	fmt.Println("\n=== Extended Type System Demo Complete ===")
}