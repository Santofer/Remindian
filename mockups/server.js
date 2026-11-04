const http = require('http');
const fs = require('fs');
const path = require('path');

const server = http.createServer((req, res) => {
  const filePath = path.join(__dirname, req.url === '/' ? '1-sidebar.html' : req.url);
  const ext = path.extname(filePath);
  const contentType = ext === '.html' ? 'text/html' : 'application/octet-stream';

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
});

server.listen(3847, () => console.log('Mockup server on http://localhost:3847'));
