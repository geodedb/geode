package gql

type Profile struct {
	Ops []struct{
		Op string `json:"op"`
		Rows int   `json:"rows"`
		InputRows int `json:"input_rows"`
		TimeNs int64 `json:"time_ns"`
		BytesAlloc int `json:"bytes_alloc"`
		PercentPeak int `json:"percent_peak"`
	} `json:"ops"`
	Totals struct{
		TimeNs int64 `json:"time_ns"`
		PeakBytes int `json:"peak_bytes"`
	} `json:"totals"`
	Spills struct{
		Sort int `json:"sort_spills"`
		Distinct int `json:"distinct_spills"`
		Union int `json:"union_spills"`
	} `json:"spills"`
	Memory struct{
		NetBytes int `json:"net_bytes"`
		PeakBytes int `json:"peak_bytes"`
		TotalAlloc int `json:"total_alloc_bytes"`
	} `json:"memory"`
	FlaggerFindings []string `json:"flagger_findings"`
	ProfileVersion int `json:"profile_version"`
}

type Explain struct {
	Logical []struct{ Op string `json:"op"`; ID int `json:"id"` } `json:"logical"`
	Properties map[string]any `json:"properties"`
	FlaggerFindings []string `json:"flagger_findings"`
}
