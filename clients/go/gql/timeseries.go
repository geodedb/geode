package gql

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// TimeSeriesPoint represents a single data point in a time series
type TimeSeriesPoint struct {
	Timestamp time.Time `json:"ts"`
	Value     float64   `json:"value"`
}

// TimeSeriesResult represents the result of a time-series query
type TimeSeriesResult struct {
	SeriesID string            `json:"series_id"`
	Points   []TimeSeriesPoint `json:"points"`
	Metadata map[string]interface{} `json:"metadata,omitempty"`
}

// TimeSeriesAggregation specifies the aggregation type for downsampling
type TimeSeriesAggregation string

const (
	TSAggAvg   TimeSeriesAggregation = "avg"
	TSAggSum   TimeSeriesAggregation = "sum"
	TSAggMin   TimeSeriesAggregation = "min"
	TSAggMax   TimeSeriesAggregation = "max"
	TSAggCount TimeSeriesAggregation = "count"
	TSAggFirst TimeSeriesAggregation = "first"
	TSAggLast  TimeSeriesAggregation = "last"
)

// InterpolationMethod specifies how to interpolate between points
type InterpolationMethod string

const (
	InterpolateLinear  InterpolationMethod = "linear"
	InterpolateStep    InterpolationMethod = "step"
	InterpolateNearest InterpolationMethod = "nearest"
)

// TimeSeriesQueryBuilder helps construct time-series queries
type TimeSeriesQueryBuilder struct {
	seriesKey string
	function  string
	args      []interface{}
}

// NewTimeSeriesQuery creates a new time-series query builder
func NewTimeSeriesQuery(seriesKey string) *TimeSeriesQueryBuilder {
	return &TimeSeriesQueryBuilder{
		seriesKey: seriesKey,
	}
}

// LastValue gets the most recent value in the series
func (q *TimeSeriesQueryBuilder) LastValue() string {
	return fmt.Sprintf("RETURN last_value('%s') AS result", q.seriesKey)
}

// ValueAt gets the value at a specific timestamp
func (q *TimeSeriesQueryBuilder) ValueAt(timestamp int64) string {
	return fmt.Sprintf("RETURN value_at('%s', %d) AS result", q.seriesKey, timestamp)
}

// SampleBy downsamples the time series with aggregation
func (q *TimeSeriesQueryBuilder) SampleBy(intervalMs int64, startTs int64, endTs int64, aggregation TimeSeriesAggregation) string {
	return fmt.Sprintf("RETURN sample_by('%s', %d, %d, %d, '%s') AS result", 
		q.seriesKey, intervalMs, startTs, endTs, aggregation)
}

// Interpolate gets an interpolated value at a specific timestamp
func (q *TimeSeriesQueryBuilder) Interpolate(timestamp int64, method InterpolationMethod) string {
	return fmt.Sprintf("RETURN interpolate('%s', %d, '%s') AS result", 
		q.seriesKey, timestamp, method)
}

// MovingAverage calculates a moving average over the series
func (q *TimeSeriesQueryBuilder) MovingAverage(windowMs int64, stepMs int64) string {
	return fmt.Sprintf("RETURN moving_avg('%s', %d, %d) AS result", 
		q.seriesKey, windowMs, stepMs)
}

// Rate calculates the rate of change
func (q *TimeSeriesQueryBuilder) Rate(intervalMs int64) string {
	return fmt.Sprintf("RETURN rate('%s', %d) AS result", q.seriesKey, intervalMs)
}

// Derivative calculates the nth order derivative
func (q *TimeSeriesQueryBuilder) Derivative(order int) string {
	if order <= 0 {
		order = 1
	}
	return fmt.Sprintf("RETURN derivative('%s', %d) AS result", q.seriesKey, order)
}

// TimeBucket aggregates data into time buckets
func (q *TimeSeriesQueryBuilder) TimeBucket(bucketMs int64, startTs int64, endTs int64) string {
	return fmt.Sprintf("RETURN time_bucket('%s', %d, %d, %d) AS result", 
		q.seriesKey, bucketMs, startTs, endTs)
}

// ParseTimeSeriesResult parses a Value into a TimeSeriesResult
func ParseTimeSeriesResult(v Value) (*TimeSeriesResult, error) {
	if v.Kind != Object {
		return nil, fmt.Errorf("expected object value for time-series result")
	}
	
	// Handle single point result
	if ts, ok := v.Obj["ts"]; ok {
		timestamp := time.Unix(0, ts.Int*1000000) // Convert ms to ns
		value := float64(0)
		if val, ok := v.Obj["value"]; ok {
			switch val.Kind {
			case Int:
				value = float64(val.Int)
			case Dec:
				f, _ := val.Dec.Float64()
				value = f
			}
		}
		
		return &TimeSeriesResult{
			Points: []TimeSeriesPoint{{
				Timestamp: timestamp,
				Value:     value,
			}},
		}, nil
	}
	
	// Handle array of points
	if result, ok := v.Obj["result"]; ok && result.Kind == Array {
		points := make([]TimeSeriesPoint, 0, len(result.Arr))
		for _, item := range result.Arr {
			if item.Kind != Object {
				continue
			}
			
			ts, hasTs := item.Obj["ts"]
			if !hasTs {
				continue
			}
			
			timestamp := time.Unix(0, ts.Int*1000000)
			value := float64(0)
			hasValue := false
			
			// Try different value fields
			for _, field := range []string{"value", "avg", "rate", "derivative"} {
				if val, ok := item.Obj[field]; ok {
					switch val.Kind {
					case Int:
						value = float64(val.Int)
						hasValue = true
					case Dec:
						f, _ := val.Dec.Float64()
						value = f
						hasValue = true
					case Null:
						// Skip null values - don't add this point
						hasValue = false
					}
					break
				}
			}
			
			// Only add points with non-null values
			if hasValue {
				points = append(points, TimeSeriesPoint{
					Timestamp: timestamp,
					Value:     value,
				})
			}
		}
		
		return &TimeSeriesResult{
			Points: points,
		}, nil
	}
	
	return nil, fmt.Errorf("unable to parse time-series result")
}

// QueryTimeSeries executes a time-series query and returns the result
func (db *DB) QueryTimeSeries(ctx context.Context, query string) (*TimeSeriesResult, error) {
	conn, err := db.Connect(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	
	iter, err := conn.NewIterator(ctx, query, nil, db.pageSize)
	if err != nil {
		return nil, err
	}
	
	row, err := iter.Next()
	if err != nil {
		return nil, err
	}
	
	if result, ok := row["result"]; ok {
		return ParseTimeSeriesResult(result)
	}
	
	// Try to parse the entire row as a time-series result
	return ParseTimeSeriesResult(Value{Kind: Object, Obj: row})
}

// InsertTimeSeriesData inserts time-series data points
func (db *DB) InsertTimeSeriesData(ctx context.Context, seriesKey string, points []TimeSeriesPoint) error {
	// Convert points to JSON for insertion
	data := make([]map[string]interface{}, len(points))
	for i, p := range points {
		data[i] = map[string]interface{}{
			"ts":    p.Timestamp.UnixMilli(),
			"value": p.Value,
		}
	}
	
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}
	
	// Create insertion query
	query := fmt.Sprintf("CALL db.ts.insert('%s', '%s')", seriesKey, jsonData)
	
	conn, err := db.Connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	
	iter, err := conn.NewIterator(ctx, query, nil, db.pageSize)
	if err != nil {
		return err
	}
	
	// Consume any results
	for {
		_, err := iter.Next()
		if err != nil {
			if err.Error() == "EOF" {
				return nil
			}
			return err
		}
	}
}