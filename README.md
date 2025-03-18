# Lock-InDashboard

A Windows solution that combines a Tailwind CSS frontend with PowerShell automation to create a ui interface for managing processes

## Features

- **Process Management**: Start and stop Windows processes from a user-friendly dashboard
- **System Monitoring**: View running processes with memory usage in real-time
- **PowerShell Backend**: Robust server implementation with RESTful API endpoints

## Quick Start

1. Clone the repository:
   ```bash
   git clone https://github.com/NSYCoding/Lock-InDashboard.git
   cd Lock-InDashboard
   ```
2. No need to compile Tailwind CSS as it's already built and ready to use.

3. Run the PowerShell server:
   ```bash
   pwsh -File server.ps1
   ```

4. Open your browser at http://localhost:2000

## Technical Stack

- **Frontend**: HTML5, Tailwind CSS 4.0, JavaScript
- **Backend**: PowerShell HTTP server with RESTful API
- **Data Storage**: JSON-based persistence
- **System Integration**: Native Windows process management via PowerShell

## API Endpoints

- **GET /api/name** - Get current user name
- **GET /api/processes** - List all running processes
- **POST /api/stop** - Stop a process by ID or name
- **POST /api/add** - Start a new process

## License

This project is licensed under the MIT License - see the LICENSE file for details.