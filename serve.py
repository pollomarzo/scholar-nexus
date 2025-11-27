from flask import Flask, send_from_directory
import os

app = Flask(__name__)
NEXUS_DIR = os.path.abspath("nexus")

@app.route('/')
def home():
    # Serve the manually generated homepage
    return send_from_directory(NEXUS_DIR, 'index.html')

@app.route('/papers/<path:filename>')
def serve_paper(filename):
    # filename will be like "repo_name/index.html" or "repo_name/_static/style.css"
    # The actual path on disk is nexus/content/papers/<repo_name>/_build/html/<rest_of_path>
    
    parts = filename.split('/', 1)
    if len(parts) < 2:
        return "Invalid path", 404
        
    repo_name = parts[0]
    rest_of_path = parts[1]
    
    paper_build_dir = os.path.join(NEXUS_DIR, 'content', 'papers', repo_name, '_build', 'html')
    return send_from_directory(paper_build_dir, rest_of_path)

if __name__ == '__main__':
    app.run(debug=True, port=5000)
