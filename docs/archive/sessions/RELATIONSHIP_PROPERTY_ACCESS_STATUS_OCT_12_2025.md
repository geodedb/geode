# Relationship Property Access Implementation Status
**Date:** October 12, 2025
**Status:** 🔧 IN PROGRESS - Debugging Required

## 🎯 Objective
Implement property access for relationship variables (e.g., `MATCH ()-[r:KNOWS]->() RETURN r.strength`)

## ✅ Completed Work

### 1. Critical Bug Fixed: Edge Property Persistence
**Problem:** Edge properties were NOT being saved to or loaded from disk
**Root Cause:**
- `saveToFile()` hardcoded property count to 0 for edges (line 538-539)
- `loadFromFile()` skipped reading edge properties (line 828-830)

**Fix Applied:** `src/graph_store.zig`
- Lines 538-590: Implemented full edge property serialization (mirrors node property code)
- Lines 828-884: Implemented full edge property deserialization

**Verification:**
```bash
CREATE (:A)-[:TEST {prop: 'value'}]->(:B)
MATCH ()-[r:TEST]->() RETURN r
# Output: {"properties":{"prop":"value"}} ✅
```

---

### 2. Edge Property Access Implementation (eval.zig)
**Added:** Lines 1318-1343 in `src/eval.zig`

```zig
.Edge => |edge| {
    if (edge.properties.get(pa.property)) |val| {
        const result = switch (val) {
            .String => |s| Value{ .Str = s },
            .Int => |i| Value{ .Int = i },
            .Float => |f| Value{ .Decimal = ... },
            .Bool => |b| Value{ .Bool = b },
            .Null => Value{ .Null = {} },
            .ExtValue => |ext| Value{ .ExtValue = ext },
        };
        break :blk_property result;
    }
},
```

**Pattern:** Mirrors Node property access implementation exactly

---

## 🐛 Current Issue: Property Access Returns Null

### Symptoms
```gql
-- Edge clearly has property:
MATCH ()-[r:TEST]->() RETURN r
=> {"id":10,"properties":{"prop":"value"}} ✅

-- But property access returns null:
MATCH ()-[r:TEST]->() RETURN r.prop
=> null ❌
```

### What Works
- ✅ Edge persistence (edges survive database reload)
- ✅ Edge property persistence (properties survive database reload)
- ✅ Returning full edge `r` (shows properties in JSON)
- ✅ `type(r)` function (returns edge label correctly)
- ✅ Node property access `n.property` (works perfectly)

### What Doesn't Work
- ❌ Edge property access `r.property` (always returns null)

---

## 🔍 Investigation Steps Taken

### 1. Verified Edge Has Properties
```bash
MATCH ()-[r:HAS {value: 42}]->() RETURN r
# Output clearly shows: "properties": {"value": 42}
```
**Conclusion:** Properties exist and are loaded correctly

### 2. Verified Environment Binding
- Tested `type(r)` - works (proves `r` is in environment)
- Tested `RETURN r` - works (proves Edge pointer is valid)
**Conclusion:** Environment contains correct Edge pointer

### 3. Compared with Node Property Access
```bash
CREATE (n:Test {name: 'Alice'}) RETURN n.name
# Output: ["Alice"] ✅ (Node properties work perfectly)
```
**Conclusion:** PropertyAccess mechanism itself works

### 4. Code Structure Review
- PropertyAccess uses identical code pattern for Node and Edge
- Both use `object.properties.get(pa.property)`
- Switched from if statements to switch for cleaner logic
**Conclusion:** Code structure appears correct

---

## 🤔 Hypotheses Under Investigation

### Hypothesis 1: Property Key Mismatch
**Theory:** Property keys might be stored/compared differently
**Status:** Adding debug output to verify
**Code Added:** Lines 1320-1327 print property keys and lookup attempts

### Hypothesis 2: Edge Pointer Issue
**Theory:** Edge pointer in environment might differ from persisted edge
**Status:** Need to verify pointer addresses match
**Evidence Against:** `type(r)` and returning `r` both work correctly

### Hypothesis 3: Evaluation Order Issue
**Theory:** PropertyAccess evaluation might happen before properties are loaded
**Status:** Unlikely given that `RETURN r` shows properties
**Evidence Against:** JSON serialization successfully accesses properties

---

## 📝 Debug Code Added (Currently Has Compilation Error)

```zig
.Edge => |edge| {
    const stderr = std.io.getStdErr().writer();  // ← ERROR: wrong API
    stderr.print("DEBUG: Edge has {d} properties, looking for '{s}'\n",
                 .{edge.properties.count(), pa.property}) catch {};

    var iter = edge.properties.iterator();
    while (iter.next()) |entry| {
        stderr.print("  - property key: '{s}'\n", .{entry.key_ptr.*}) catch {};
    }

    if (edge.properties.get(pa.property)) |val| {
        // ... return value
    } else {
        stderr.print("DEBUG: Property not found\n", .{}) catch {};
    }
},
```

**Compilation Error:** `std.io.getStdErr` API incorrect for this Zig version
**Fix Needed:** Update to correct stderr API

---

## 🎯 Next Steps (Priority Order)

### 1. Fix Debug Code and Test [IMMEDIATE]
**Action:** Fix stderr API call
**Correct API:** Check Zig 0.15.1 docs for proper stderr access
**Goal:** See actual property keys and lookup behavior

### 2. Verify Property Key Storage
**Test:** Add debug to edge property serialization
**Check:** Are keys being saved/loaded with same string representation?

### 3. Compare Memory Addresses
**Test:** Print Edge pointer address at binding vs. evaluation
**Goal:** Verify we're accessing the same Edge instance

### 4. Test Property Access in CREATE
**Query:** `CREATE ()-[r:T {x: 1}]->() RETURN r.x`
**Goal:** See if issue is specific to MATCH or affects CREATE too
**Current Result:** Returns null (same issue)

---

## 📊 Files Modified

1. **`src/graph_store.zig`**
   - Lines 538-590: Edge property serialization
   - Lines 828-884: Edge property deserialization
   - **Status:** ✅ Working - properties persist correctly

2. **`src/eval.zig`**
   - Lines 1298-1349: PropertyAccess with Edge support
   - **Status:** 🐛 Not working - returns null instead of property value

3. **`src/execution.zig`** (from previous work)
   - Lines 2361-2363, 2478-2485: Relationship variable binding in CREATE
   - Lines 2747-2777: Environment construction with relationships
   - **Status:** ✅ Working - relationship variables bind correctly

---

## 🧪 Test Cases

### Passing Tests
```bash
# Edge creation and retrieval
CREATE (:A)-[:TEST {prop: 'value'}]->(:B)
MATCH ()-[r:TEST]->() RETURN r
=> Shows properties ✅

# Edge label access
MATCH ()-[r:TEST]->() RETURN type(r)
=> "TEST" ✅

# Node property access
CREATE (n {name: 'Alice'}) RETURN n.name
=> "Alice" ✅
```

### Failing Tests
```bash
# Edge property access
MATCH ()-[r:TEST {prop: 'value'}]->() RETURN r.prop
=> null ❌ (should be "value")

# Edge integer property
CREATE ()-[r:HAS {value: 42}]->() RETURN r.value
=> null ❌ (should be 42)

# geode_migrations tests
migrate-relationship-properties: missing 'strong'
change-relationship-direction: missing 'FOLLOWED_BY'
```

---

## 💡 Key Insights

1. **Edge infrastructure is solid**
   - Persistence works correctly
   - Variable binding works correctly
   - Properties are stored and retrieved correctly

2. **Issue is isolated to PropertyAccess evaluation**
   - Only affects `r.property` syntax
   - Does not affect `r` itself or `type(r)`
   - Does not affect node properties

3. **Likely a subtle bug in eval.zig**
   - Code structure looks correct
   - Pattern matches working Node implementation
   - Suggests issue with HashMap.get() call or property name handling

---

## 🔧 Recommended Debug Strategy

1. **Add minimal debug output** (fix compilation error first)
2. **Run:** `MATCH ()-[r:TEST {x: 'y'}]->() RETURN r.x 2>&1`
3. **Observe:**
   - Does debug print appear? (confirms Edge branch is reached)
   - How many properties does edge have?
   - What are the exact property key strings?
   - Does `properties.get()` find the property?

4. **If property is found:** Issue is in value conversion
5. **If property not found:** Issue is in key matching or storage

---

## 📈 Impact

**Tests Blocked:** 2-3 geode_migrations tests waiting for this fix
**Feature:** Core GQL compliance feature
**Priority:** HIGH - Required for relationship property manipulation

---

## 🚀 Once Fixed, Will Enable

- ✅ `MATCH ()-[r]->() RETURN r.property`
- ✅ `MATCH ()-[r]->() SET r.property = value`
- ✅ `migrate-relationship-properties` test
- ✅ Complete relationship feature parity with nodes

---

*Status: Awaiting debug output results*
*Next Session: Fix stderr API → Add debug → Identify root cause*
