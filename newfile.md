```sql
UPDATE testing.result r
SET successfully = false
    FROM testing.test t
WHERE r.invest_id = :investId::uuid
  AND r.test_id = t.id
  AND t.type = :testType::testing.test_type
  AND r.successfully = true
    RETURNING r.id as id, r.successfully as successfully, r.test_id as test_id,
    r.invest_id as invest_id, r.inserted as inserted
```