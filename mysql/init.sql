USE myapp;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nama VARCHAR(100) NOT NULL,
    nim VARCHAR(20) NOT NULL UNIQUE
) ENGINE=InnoDB;

-- Tabel untuk uji tulis (action=dbwrite)
CREATE TABLE IF NOT EXISTS bench_log (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    payload VARCHAR(255) NOT NULL,
    created_at DATETIME(6) NOT NULL
) ENGINE=InnoDB;

-- Isi 500 baris dengan recursive CTE (tanpa stored procedure / DELIMITER)
SET SESSION cte_max_recursion_depth = 5000;

INSERT INTO users (nama, nim)
WITH RECURSIVE seq (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 500
)
SELECT CONCAT('Mahasiswa ', n), CONCAT('101', LPAD(n, 5, '0')) FROM seq;
