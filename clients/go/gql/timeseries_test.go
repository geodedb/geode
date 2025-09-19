package gql

import (
	"math/big"
	"testing"
	"time"
)

func TestTimeSeriesQueryBuilder(t *testing.T) {
	tests := []struct {
		name     string
		build    func() string
		expected string
	}{
		{
			name: "LastValue",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.LastValue()
			},
			expected: "RETURN last_value('device:1:temp') AS result",
		},
		{
			name: "ValueAt",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.ValueAt(1000000)
			},
			expected: "RETURN value_at('device:1:temp', 1000000) AS result",
		},
		{
			name: "SampleBy",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.SampleBy(10000, 1000, 2000, TSAggAvg)
			},
			expected: "RETURN sample_by('device:1:temp', 10000, 1000, 2000, 'avg') AS result",
		},
		{
			name: "Interpolate",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.Interpolate(1500, InterpolateLinear)
			},
			expected: "RETURN interpolate('device:1:temp', 1500, 'linear') AS result",
		},
		{
			name: "MovingAverage",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.MovingAverage(5000, 1000)
			},
			expected: "RETURN moving_avg('device:1:temp', 5000, 1000) AS result",
		},
		{
			name: "Rate",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.Rate(1000)
			},
			expected: "RETURN rate('device:1:temp', 1000) AS result",
		},
		{
			name: "Derivative",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.Derivative(1)
			},
			expected: "RETURN derivative('device:1:temp', 1) AS result",
		},
		{
			name: "TimeBucket",
			build: func() string {
				q := NewTimeSeriesQuery("device:1:temp")
				return q.TimeBucket(60000, 1000000, 2000000)
			},
			expected: "RETURN time_bucket('device:1:temp', 60000, 1000000, 2000000) AS result",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.build()
			if got != tt.expected {
				t.Errorf("got %q, want %q", got, tt.expected)
			}
		})
	}
}

func TestParseTimeSeriesResult(t *testing.T) {
	tests := []struct {
		name    string
		value   Value
		want    int // expected number of points
		wantErr bool
	}{
		{
			name: "SinglePoint",
			value: Value{
				Kind: Object,
				Obj: map[string]Value{
					"ts":    {Kind: Int, Int: 1000000},
					"value": {Kind: Int, Int: 25},
				},
			},
			want:    1,
			wantErr: false,
		},
		{
			name: "ArrayOfPoints",
			value: Value{
				Kind: Object,
				Obj: map[string]Value{
					"result": {
						Kind: Array,
						Arr: []Value{
							{
								Kind: Object,
								Obj: map[string]Value{
									"ts":    {Kind: Int, Int: 1000000},
									"value": {Kind: Int, Int: 25},
								},
							},
							{
								Kind: Object,
								Obj: map[string]Value{
									"ts":    {Kind: Int, Int: 2000000},
									"value": {Kind: Int, Int: 26},
								},
							},
						},
					},
				},
			},
			want:    2,
			wantErr: false,
		},
		{
			name: "AverageResult",
			value: Value{
				Kind: Object,
				Obj: map[string]Value{
					"result": {
						Kind: Array,
						Arr: []Value{
							{
								Kind: Object,
								Obj: map[string]Value{
									"ts":  {Kind: Int, Int: 1000000},
									"avg": {Kind: Int, Int: 25},
								},
							},
						},
					},
				},
			},
			want:    1,
			wantErr: false,
		},
		{
			name: "RateResult",
			value: Value{
				Kind: Object,
				Obj: map[string]Value{
					"result": {
						Kind: Array,
						Arr: []Value{
							{
								Kind: Object,
								Obj: map[string]Value{
									"ts":   {Kind: Int, Int: 1000000},
									"rate": {Kind: Dec, Dec: big.NewRat(5, 2)},
								},
							},
						},
					},
				},
			},
			want:    1,
			wantErr: false,
		},
		{
			name: "InvalidType",
			value: Value{
				Kind: Str,
				Str:  "not an object",
			},
			want:    0,
			wantErr: true,
		},
		{
			name: "NullValues",
			value: Value{
				Kind: Object,
				Obj: map[string]Value{
					"result": {
						Kind: Array,
						Arr: []Value{
							{
								Kind: Object,
								Obj: map[string]Value{
									"ts":    {Kind: Int, Int: 1000000},
									"value": {Kind: Null},
								},
							},
							{
								Kind: Object,
								Obj: map[string]Value{
									"ts":    {Kind: Int, Int: 2000000},
									"value": {Kind: Int, Int: 26},
								},
							},
						},
					},
				},
			},
			want:    1, // Only non-null value
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseTimeSeriesResult(tt.value)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseTimeSeriesResult() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if err == nil && len(got.Points) != tt.want {
				t.Errorf("ParseTimeSeriesResult() got %d points, want %d", len(got.Points), tt.want)
			}
		})
	}
}

func TestTimeSeriesPoint(t *testing.T) {
	// Test timestamp conversion
	now := time.Now()
	nowMs := now.UnixMilli()
	
	point := TimeSeriesPoint{
		Timestamp: time.Unix(0, nowMs*1000000),
		Value:     25.5,
	}
	
	if point.Timestamp.UnixMilli() != nowMs {
		t.Errorf("Timestamp conversion failed: got %d, want %d", point.Timestamp.UnixMilli(), nowMs)
	}
	
	if point.Value != 25.5 {
		t.Errorf("Value mismatch: got %f, want %f", point.Value, 25.5)
	}
}

func TestTimeSeriesAggregation(t *testing.T) {
	aggregations := []TimeSeriesAggregation{
		TSAggAvg,
		TSAggSum,
		TSAggMin,
		TSAggMax,
		TSAggCount,
		TSAggFirst,
		TSAggLast,
	}
	
	expected := []string{"avg", "sum", "min", "max", "count", "first", "last"}
	
	for i, agg := range aggregations {
		if string(agg) != expected[i] {
			t.Errorf("Aggregation %d: got %s, want %s", i, agg, expected[i])
		}
	}
}

func TestInterpolationMethod(t *testing.T) {
	methods := []InterpolationMethod{
		InterpolateLinear,
		InterpolateStep,
		InterpolateNearest,
	}
	
	expected := []string{"linear", "step", "nearest"}
	
	for i, method := range methods {
		if string(method) != expected[i] {
			t.Errorf("Interpolation method %d: got %s, want %s", i, method, expected[i])
		}
	}
}