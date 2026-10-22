-- Pastikan database dipilih
USE myapp;

-- 1. Buat Tabel
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    nama VARCHAR(100) NOT NULL,
    nim VARCHAR(20) NOT NULL UNIQUE
);

-- 2. Buat Stored Procedure untuk Generate Data
DELIMITER $$

CREATE PROCEDURE GenerateDummyUsers()
BEGIN
    DECLARE i INT DEFAULT 1;
    
    -- Cek apakah tabel kosong agar tidak duplikat saat restart
    IF (SELECT COUNT(*) FROM users) = 0 THEN
        WHILE i <= 50 DO
            INSERT INTO users (nama, nim) VALUES (
                CONCAT('Mahasiswa ', i),             -- Hasil: Mahasiswa 1
                CONCAT('101', LPAD(i, 5, '0'))       -- Hasil: 10100001
            );
            SET i = i + 1;
        END WHILE;
    END IF;
END$$

DELIMITER ;

-- 3. Jalankan Procedure
CALL GenerateDummyUsers();

-- 4. Hapus Procedure (bersih-bersih)
DROP PROCEDURE GenerateDummyUsers;