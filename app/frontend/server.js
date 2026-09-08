const express = require('express');
const path = require('path');
const fetch = require('node-fetch');

const app = express();
app.use(express.json());

app.use(express.static(path.join(__dirname, 'public')));

const BACKEND_URL = process.env.BACKEND_URL || 'http://localhost:3001';

app.get('/api/tasks', async (req, res) => {
    try {
        const response = await fetch(`${BACKEND_URL}/api/tasks`);
        const data = await response.json();
        res.json(data);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.post('/api/tasks', async (req, res) => {
    try {
        const response = await fetch(`${BACKEND_URL}/api/tasks`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(req.body)
        });
        const data = await response.json();
        res.json(data);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

app.get('/health', (req, res) => {
    res.status(200).send('Frontend is healthy');
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`Frontend server running on port ${PORT}`);
});