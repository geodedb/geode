package gql

import (
	"reflect"
)

func StructScan[T any](row map[string]Value, dest *T) error {
	rv := reflect.ValueOf(dest).Elem()
	rt := rv.Type()
	for i := 0; i < rt.NumField(); i++ {
		f := rt.Field(i)
		name := f.Name
		if v, ok := row[name]; ok {
			fv := rv.Field(i)
			switch v.Kind {
			case Int:
				if fv.Kind() == reflect.Int64 || fv.Kind() == reflect.Int {
					fv.SetInt(v.Int)
				}
			case Bool:
				if fv.Kind() == reflect.Bool {
					fv.SetBool(v.Bool)
				}
			case Str:
				if fv.Kind() == reflect.String {
					fv.SetString(v.Str)
				}
			}
		}
	}
	return nil
}

func IsNull(v Value) bool { return v.Kind == Null }
