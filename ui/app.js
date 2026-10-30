const API_URL = "/api/tasks";

const taskForm = document.getElementById("task-form");
const titleInput = document.getElementById("title");
const descriptionInput = document.getElementById("description");
const taskList = document.getElementById("task-list");
const taskCount = document.getElementById("task-count");
const message = document.getElementById("message");
const submitButton = document.getElementById("submit-button");
const refreshButton = document.getElementById("refresh-button");

function showMessage(text, type = "") {
    message.textContent = text;
    message.className = type;
}

async function apiRequest(url, options = {}) {
    const response = await fetch(url, {
        ...options,
        headers: {
            "Content-Type": "application/json",
            ...options.headers
        }
    });

    if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `HTTP ${response.status}`);
    }

    if (response.status === 204) {
        return null;
    }

    return response.json();
}

function createTaskElement(task) {
    const item = document.createElement("li");
    item.className = "task-item";
    if (task.completed) item.classList.add("completed");

    const heading = document.createElement("h3");
    heading.textContent = task.title;

    const description = document.createElement("p");
    description.textContent = task.description || "No description";

    const status = document.createElement("span");
    status.className = "status";
    status.textContent = task.completed ? "Completed" : "Pending";

    const actions = document.createElement("div");
    actions.className = "task-actions";

    const completeButton = document.createElement("button");
    completeButton.textContent = task.completed
        ? "Mark Pending"
        : "Mark Complete";

    completeButton.addEventListener("click", async () => {
        try {
            await apiRequest(`${API_URL}/${task.id}`, {
                method: "PATCH",
                body: JSON.stringify({ completed: !task.completed })
            });
            showMessage("Task status updated.", "success");
            await loadTasks();
        } catch (error) {
            showMessage(`Update failed: ${error.message}`, "error");
        }
    });

    const deleteButton = document.createElement("button");
    deleteButton.textContent = "Delete";
    deleteButton.className = "delete";

    deleteButton.addEventListener("click", async () => {
        if (!window.confirm(`Delete "${task.title}"?`)) return;

        try {
            await apiRequest(`${API_URL}/${task.id}`, {
                method: "DELETE"
            });
            showMessage("Task deleted.", "success");
            await loadTasks();
        } catch (error) {
            showMessage(`Delete failed: ${error.message}`, "error");
        }
    });

    actions.append(completeButton, deleteButton);
    item.append(heading, description, status, actions);

    return item;
}

async function loadTasks() {
    taskCount.textContent = "Loading tasks...";
    taskList.replaceChildren();

    try {
        const tasks = await apiRequest(API_URL);

        tasks.forEach(task => {
            taskList.appendChild(createTaskElement(task));
        });

        const completed = tasks.filter(task => task.completed).length;
        taskCount.textContent =
            `${tasks.length} tasks · ${completed} completed`;

        if (tasks.length === 0) {
            taskCount.textContent = "No tasks yet. Add your first task!";
        }
    } catch (error) {
        taskCount.textContent = "Could not load tasks.";
        showMessage(`API error: ${error.message}`, "error");
    }
}

taskForm.addEventListener("submit", async event => {
    event.preventDefault();
    submitButton.disabled = true;

    try {
        await apiRequest(API_URL, {
            method: "POST",
            body: JSON.stringify({
                title: titleInput.value.trim(),
                description: descriptionInput.value.trim()
            })
        });

        taskForm.reset();
        showMessage("Task created successfully.", "success");
        await loadTasks();
    } catch (error) {
        showMessage(`Could not create task: ${error.message}`, "error");
    } finally {
        submitButton.disabled = false;
    }
});

refreshButton.addEventListener("click", loadTasks);

loadTasks();
