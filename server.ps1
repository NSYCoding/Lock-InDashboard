# Process Management HTTP Server
# Global variables
$jsonFile = "./data.json"
$staticFilesDir = "./src/"

# Initialize tracking variables
$script:serverStartTime = Get-Date
$script:requestCount = 0
$script:shuttingDown = $false

# MIME type definitions for static file serving
$mimeTypes = @{
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "text/javascript"
    ".json" = "application/json" 
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
}

function Get-Json {
    if (-not (Test-Path -Path $jsonFile)) {
        return "[]"
    }
    try {
        $content = Get-Content $jsonFile -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            return "[]"
        }
        return $content
    }
    catch {
        Write-Error "Error reading JSON: $_"
        return "[]"
    }
}

function Set-Json {
    param (
        [Parameter(Position = 0)]
        $Json
    )
    try {
        $Json | ConvertTo-Json -Depth 100 | Out-File $jsonFile -Force
        return $Json | ConvertTo-Json -Depth 100
    }
    catch {
        Write-Error "Error writing JSON: $_"
        return '{"error": "Failed to save data"}'
    }
}

function Send-StaticFile {
    param (
        [string]$LocalPath,
        $Response
    )
    
    # Determine the file path
    $filePath = if ($LocalPath -eq "/" -or [string]::IsNullOrEmpty($LocalPath)) {
        # Default to index.html
        Join-Path -Path $staticFilesDir -ChildPath "index.html"
    }
    else {
        # Remove leading slash if present
        $cleanPath = $LocalPath.TrimStart('/')
        Join-Path -Path $staticFilesDir -ChildPath $cleanPath
    }
    
    Write-Host "Attempting to serve file: $filePath"
    
    if (Test-Path -Path $filePath -PathType Leaf) {
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()
        $contentType = $mimeTypes[$extension]
        if (-not $contentType) {
            $contentType = "application/octet-stream"
        }
        
        $Response.ContentType = $contentType
        
        $fileContent = [System.IO.File]::ReadAllBytes($filePath)
        
        $Response.ContentLength64 = $fileContent.Length
        $Response.OutputStream.Write($fileContent, 0, $fileContent.Length)
        
        # Track request
        $script:requestCount++
        
        return $true
    }
    else {
        Write-Host "File not found: $filePath" -ForegroundColor Yellow
        $Response.StatusCode = 404
        $Response.ContentType = "text/plain"
        $errorMessage = "File not found: $LocalPath"
        $errorBytes = [System.Text.Encoding]::UTF8.GetBytes($errorMessage)
        $Response.ContentLength64 = $errorBytes.Length
        $Response.OutputStream.Write($errorBytes, 0, $errorBytes.Length)
        
        # Still track the request even though it's a 404
        $script:requestCount++
        
        return $false
    }
}

function Start-Server {
    # Reset tracking variables
    $script:serverStartTime = Get-Date
    $script:requestCount = 0
    $script:shuttingDown = $false
    
    # Create data file if needed
    if (-not (Test-Path -Path $jsonFile)) {
        Write-Host "Creating empty data file: $jsonFile"
        "[]" | Out-File -FilePath $jsonFile -Force
    }
    
    # Create static files directory if needed
    if (-not (Test-Path -Path $staticFilesDir)) {
        Write-Host "Creating static files directory: $staticFilesDir"
        New-Item -ItemType Directory -Path $staticFilesDir -Force
    }
    
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:2000/")
    $listener.Start()
    Write-Host "Server started on port 2000"
    Write-Host "Open your browser at http://localhost:2000/"

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            
            # Handle preflight requests
            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 200
                $response.Close()
                continue
            }

            $url = $request.Url
            
            # Get request body if present
            $body = ""
            if ($request.HasEntityBody) {
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
            
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $($request.HttpMethod) $($url.LocalPath)" -ForegroundColor Cyan
            
            # Track the API request
            $script:requestCount++

            # Handle based on path
            try {
                switch -Regex ($url.LocalPath) {
                    "/api/name" {
                        $response.ContentType = "application/json"
                        try {
                            $fullUsername = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
                            # Extract just the username part after the domain\
                            $username = $fullUsername -replace '.*\\', ''
                        } catch {
                            $username = "Unknown User"
                            Write-Error "Failed to retrieve username: $_"
                        }
                        # Use "name" instead of "username" to match client expectations
                        $responseBody = "{`"name`": `"$username`"}"
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        break
                    }
                    "/api/status" {
                        $response.ContentType = "application/json"
                        try {
                            # Get basic system info
                            $computerInfo = Get-CimInstance -ClassName Win32_OperatingSystem
                            $uptime = (Get-Date) - $computerInfo.LastBootUpTime
                            
                            # Format server status information
                            $statusInfo = @{
                                serverRunning = $true
                                serverStartTime = $script:serverStartTime.ToString("yyyy-MM-dd HH:mm:ss")
                                serverUptime = "{0}d {1}h {2}m {3}s" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
                                totalRequests = $script:requestCount
                                systemMemoryFree = [math]::Round($computerInfo.FreePhysicalMemory / 1MB, 2)
                                totalProcesses = (Get-Process).Count
                            }
                            
                            $responseBody = $statusInfo | ConvertTo-Json
                        }
                        catch {
                            $response.StatusCode = 500
                            $responseBody = "{`"error`": `"Failed to get server status`"}"
                        }
                        
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        break
                    }
                    "/api/processes" {
                        $response.ContentType = "application/json"
                        try {
                            $processes = Get-Process | Select-Object -Property Id, Name, 
                                @{Name = "CPU"; Expression = { if ($_.CPU) { $_.CPU } else { 0 } } }, 
                                @{Name = "Memory"; Expression = { [math]::Round($_.WorkingSet64 / 1MB, 2) } }
                            $responseBody = $processes | ConvertTo-Json -Depth 2
                        }
                        catch {
                            $response.StatusCode = 500
                            $responseBody = '{"error": "Failed to get processes"}'
                        }
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        break
                    }
                    "/api/stop" {
                        $response.ContentType = "application/json"
                        try {
                            $processData = $body | ConvertFrom-Json
                            
                            # Check if we have a process ID or name
                            if ($processData.Id) {
                                # Stop by ID
                                try {
                                    $processId = [int]$processData.Id
                                    $process = Get-Process -Id $processId -ErrorAction Stop
                                    $processName = $process.Name
                                    $process.Kill()
                                    Write-Host "Process $processName (ID: $processId) killed successfully" -ForegroundColor Green
                                    $responseBody = "{`"success`": true, `"message`": `"Process $processName with ID $processId stopped`"}"
                                }
                                catch {
                                    throw "Failed to find or stop process with ID $processId`: $($_.Exception.Message)"
                                }
                            }
                            elseif ($processData.Name) {
                                # Stop by Name
                                $processName = $processData.Name
                                try {
                                    # Check if the process exists first
                                    $processes = Get-Process -Name $processName -ErrorAction Stop
                                    $count = $processes.Count
                                    
                                    if ($count -gt 0) {
                                        # Kill all matching processes
                                        $processes | ForEach-Object { $_.Kill() }
                                        Write-Host "Process $processName ($count instances) killed successfully" -ForegroundColor Green
                                        $responseBody = "{`"success`": true, `"message`": `"$count instances of $processName stopped`"}"
                                    }
                                    else {
                                        throw "No processes with name $processName were found"
                                    }
                                }
                                catch {
                                    throw "Failed to find or stop process named $processName`: $($_.Exception.Message)"
                                }
                            }
                            else {
                                throw "Either Process ID or Name is required"
                            }
                        }
                        catch {
                            Write-Error "Error stopping process: $_"
                            $response.StatusCode = 400
                            $errorMessage = $_.Exception.Message -replace '"', '\"'
                            $responseBody = "{`"success`": false, `"error`": `"$errorMessage`"}"
                        }
                        
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        break
                    }
                    "/api/add" {
                        $response.ContentType = "application/json"
                        try {
                            # Parse the request body into $newData
                            $newData = $body | ConvertFrom-Json

                            # Create new process object
                            $newProcess = New-Object PSObject
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Name" -Value $newData.Name
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Path" -Value $newData.Path
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Arguments" -Value $newData.Arguments
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Id" -Value $null

                            # Validate required fields
                            if (-not $newProcess.Name) {
                                throw "Process name is required"
                            }

                            # Try to resolve the executable path if not provided
                            if (-not $newProcess.Path) {
                                try {
                                    # Try to find the executable in PATH
                                    $processPath = (Get-Command $newProcess.Name -ErrorAction Stop).Path
                                    $newProcess.Path = $processPath
                                }
                                catch {
                                    # Use the name as the path if not found
                                    $newProcess.Path = $newProcess.Name
                                }
                            }

                            Write-Host "Attempting to start process: $($newProcess.Path)" -ForegroundColor Cyan

                            # Start the added process
                            $processArgs = @{
                                FilePath    = $newProcess.Path
                                PassThru    = $true
                                ErrorAction = "Stop"
                            }

                            if ($newProcess.Arguments) {
                                $processArgs.ArgumentList = $newProcess.Arguments
                            }

                            # Try to start the process
                            $process = Start-Process @processArgs

                            if ($process) {
                                # Update with actual process ID
                                $newProcess.Id = $process.Id
            
                                # Add the new data to the existing JSON
                                $jsonData = Get-Json | ConvertFrom-Json
                                $jsonData += $newProcess
            
                                # Save the updated data
                                Set-Json -Json $jsonData
            
                                $responseBody = "{`"success`": true, `"message`": `"Process $($newProcess.Name) started with ID $($process.Id)`"}"
                                Write-Host "Process $($newProcess.Name) (path: $($newProcess.Path)) started with ID $($process.Id)" -ForegroundColor Green
                            }
                            else {
                                throw "Failed to start process $($newProcess.Name) - no process returned"
                            }
                        }
                        catch {
                            Write-Error "Error starting process: $_"
                            $response.StatusCode = 400
                            $errorMessage = $_.Exception.Message -replace '"', '\"'
                            $responseBody = "{`"success`": false, `"error`": `"$errorMessage`"}"
                        }

                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        break
                    }
                    default {
                        # Serve static files
                        Send-StaticFile -LocalPath $url.LocalPath -Response $response
                    }
                }
            }
            catch {
                Write-Error "Error processing request: $_"
                $response.StatusCode = 500
                $errorMessage = "Internal Server Error: $($_.Exception.Message)"
                $errorBytes = [System.Text.Encoding]::UTF8.GetBytes($errorMessage)
                $response.ContentType = "text/plain"
                $response.ContentLength64 = $errorBytes.Length
                $response.OutputStream.Write($errorBytes, 0, $errorBytes.Length)
            }
            finally {
                $response.Close()
            }
        }
    }
    catch {
        Write-Error "Error occurred in server loop: $_"
    }
    finally {
        if ($listener -and $listener.IsListening) {
            $listener.Stop()
        }
        Write-Host "Server stopped"
    }
}

function Stop-Server {
    param (
        [Parameter(ValueFromPipeline = $true)]
        $Listener,
        
        [Parameter()]
        [switch]$Force
    )
    
    # Signal shutdown
    $script:shuttingDown = $true
    
    # Give time for current requests to complete, unless force is specified
    if (-not $Force) {
        Write-Host "Waiting for current requests to complete..."
        Start-Sleep -Seconds 3
    }
    
    if ($Listener) {
        $Listener.Stop()
        $Listener.Close()
    }
    else {
        # Fallback if listener not specified
        try {
            $ports = Get-NetTCPConnection -LocalPort 2000 -ErrorAction SilentlyContinue
            if ($ports) {
                Write-Host "Stopping server on port 2000"
                $processIds = $ports | Select-Object -ExpandProperty OwningProcess -Unique
                foreach ($pid in $processIds) {
                    Write-Host "Stopping process $pid"
                    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            Write-Error "Failed to stop server: $_"
        }
    }
    
    # Report server statistics
    $uptime = (Get-Date) - $script:serverStartTime
    Write-Host "Server stopped. Total uptime: $($uptime.ToString())"
    Write-Host "Total requests served: $script:requestCount"
}

# Start the server
Write-Host "Starting server..."
Start-Server