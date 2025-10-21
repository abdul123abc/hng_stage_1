# app.py
from flask import Flask, request, redirect, url_for

# Create the Flask application instance
app = Flask(__name__)

# Global list to store tasks. NOTE: This data is not persistent! 
# It resets every time the container is restarted.
tasks = ["Learn Docker", "Build a Web App", "Containerize the App"]

# HTML Template Generator
def get_html_template(tasks_list):
    """Generates the full HTML page with embedded task list."""
    task_items = ""
    if tasks_list:
        # Loop through tasks and create an <li> for each
        for i, task in enumerate(tasks_list):
            task_items += f"""
            <li class="flex items-center justify-between bg-white p-3 rounded-lg shadow mb-2 transition duration-150 ease-in-out hover:bg-gray-50">
                <span class="text-gray-800 text-lg font-medium">{i+1}. {task}</span>
                <span class="text-sm text-gray-400">Added locally</span>
            </li>
            """
    else:
        task_items = '<li class="text-center py-8 text-gray-500 italic">No tasks yet! Add one above.</li>'

    # The main HTML structure using Tailwind for styling
    return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Simple Containerized To-Do App</title>
    <!-- Load Tailwind CSS -->
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        body {{
            font-family: 'Inter', sans-serif;
            background-color: #f3f4f6;
        }}
    </style>
</head>
<body class="p-8">
    <div class="max-w-xl mx-auto bg-white p-8 rounded-xl shadow-2xl">
        <h1 class="text-4xl font-bold text-center mb-6 text-indigo-700">Containerized To-Do List</h1>
        <p class="text-center text-gray-500 mb-8">A slightly more functional Flask app ready for Docker!</p>

        <!-- Task Input Form -->
        <form method="POST" class="flex space-x-4 mb-10 p-4 border border-indigo-200 rounded-xl bg-indigo-50 shadow-inner">
            <input
                type="text"
                name="new_task"
                placeholder="What needs to be done?"
                required
                class="flex-grow p-3 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500"
            >
            <button
                type="submit"
                class="bg-indigo-600 hover:bg-indigo-700 text-white font-semibold py-3 px-6 rounded-lg shadow-md transition duration-300 ease-in-out transform hover:scale-105"
            >
                Add Task
            </button>
        </form>

        <!-- Task List Display -->
        <ul id="task-list" class="space-y-3">
            {task_items}
        </ul>
    </div>
</body>
</html>
"""

@app.route('/', methods=['GET', 'POST'])
def todo_list():
    """Handles both displaying the list (GET) and adding a new task (POST)."""
    if request.method == 'POST':
        # Get data from the form
        new_task = request.form.get('new_task')
        if new_task:
            tasks.append(new_task.strip())
        # Redirect back to the GET route to prevent form resubmission on refresh
        return redirect(url_for('todo_list'))

    # Handle GET request (and redirects)
    return get_html_template(tasks)

# The application runs on host 0.0.0.0 (required for Docker) and port 5000.
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)

