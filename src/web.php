<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Web Sederhana</title>
</head>
<body>
    <center>
        <h1>WEB SEDERHANA DENGAN <?= $_SERVER['SERVER_SOFTWARE'] ?? 'FrankenPHP' ?> </h1>
    </center>
    <p>
        <?= $_SERVER['SERVER_SOFTWARE'] ?? 'FrankenPHP'; ?>
    </p>
</body>
</html>