-- 查询门店
SELECT id, name, COUNT(*) AS cnt
FROM stores s
LEFT JOIN orders o ON o.store_id = s.id
WHERE s.state = 1
GROUP BY id, name
ORDER BY cnt DESC LIMIT 10;
