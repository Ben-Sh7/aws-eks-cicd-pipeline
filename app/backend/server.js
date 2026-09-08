const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const app = express();
app.use(cors());
app.use(express.json());

const pool = new Pool({
    user: process.env.DB_USER || 'postgres',
    host: process.env.DB_HOST || 'localhost',
    database: process.env.DB_NAME || 'tasksdb',
    password: process.env.DB_PASSWORD || 'postgres',
    port: process.env.DB_PORT || 5432,
});



// הוספת משימה
app.post('/api/tasks', async (req, res) => {
    try {
        const { title } = req.body;
        const result = await pool.query('INSERT INTO tasks (title) VALUES ($1) RETURNING *', [title]);
        res.status(201).json(result.rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// קבלת כל המשימות
app.get('/api/tasks', async (req, res) => {
    try {
        const result = await pool.query('SELECT * FROM tasks ORDER BY id DESC');
        res.status(200).json(result.rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// --- Health Check for Kubernetes Probes ---
app.get('/health', async (req, res) => {
    try {
        await pool.query('SELECT 1');
        res.status(200).json({ status: 'OK', database: 'Connected' });
    } catch (err) {
        console.error('Health check failed:', err);
        res.status(503).json({ status: 'Error', database: 'Disconnected' });
    }
});

async function initDB() {
    let retries = 5;
    while (retries > 0) {
        try {
            await pool.query(`
                CREATE TABLE IF NOT EXISTS tasks (
                    id SERIAL PRIMARY KEY,
                    title VARCHAR(255) NOT NULL
                )
            `);
            console.log("Database initialized successfully!");
            return; 
        } catch (err) {
            console.error(`Database not ready yet. Retries left: ${retries - 1}. Error:`, err.message);
            retries -= 1;
            await new Promise(resolve => setTimeout(resolve, 5000));
        }
    }
    
    console.error("Failed to initialize database after multiple attempts. Exiting...");
    process.exit(1); 
}

initDB().then(() => {
    const PORT = process.env.PORT || 3001;
    app.listen(PORT, () => {
        console.log(`Backend server running on port ${PORT}`);
    });
});

