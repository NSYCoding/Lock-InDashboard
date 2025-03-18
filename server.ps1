$jsonFile = "./data.json"
$staticFilesDir = "./src/"

$script:serverStartTime = Get-Date
$script:requestCount = 0
$script:shuttingDown = $false

$mimeTypes = @{
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "text/javascript"
    ".json" = "application/json" 
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
    
    $filePath = if ($LocalPath -eq "/" -or [string]::IsNullOrEmpty($LocalPath)) {
        Join-Path -Path $staticFilesDir -ChildPath "index.html"
    }
    else {
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
        
        $script:requestCount++
        
        return $false
    }
}

function Start-Server {
    $script:serverStartTime = Get-Date
    $script:requestCount = 0
    $script:shuttingDown = $false
    
    if (-not (Test-Path -Path $jsonFile)) {
        Write-Host "Creating empty data file: $jsonFile"
        "[]" | Out-File -FilePath $jsonFile -Force
    }
    
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
        while ($listener.IsListening -and -not $script:shuttingDown) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
            $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            
            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 200
                $response.Close()
                continue
            }

            $url = $request.Url
            
            $body = ""
            if ($request.HasEntityBody) {
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
            
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $($request.HttpMethod) $($url.LocalPath)" -ForegroundColor Cyan
            
            $script:requestCount++

            try {
                switch -Regex ($url.LocalPath) {
                    "/api/name" {
                        $response.ContentType = "application/json"
                        try {
                            $fullUsername = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
                            $username = $fullUsername -replace '.*\\', ''
                        } catch {
                            $username = "Unknown User"
                            Write-Error "Failed to retrieve username: $_"
                        }
                        $responseBody = "{`"name`": `"$username`"}"
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
                            
                            if ($processData.Id) {
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
                                $processName = $processData.Name
                                try {
                                    $processes = Get-Process -Name $processName -ErrorAction Stop
                                    $count = $processes.Count
                                    
                                    if ($count -gt 0) {
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
                            $newData = $body | ConvertFrom-Json

                            $newProcess = New-Object PSObject
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Name" -Value $newData.Name
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Path" -Value $newData.Path
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Arguments" -Value $newData.Arguments
                            Add-Member -InputObject $newProcess -MemberType NoteProperty -Name "Id" -Value $null

                            if (-not $newProcess.Name) {
                                throw "Process name is required"
                            }

                            if (-not $newProcess.Path) {
                                try {
                                    $processPath = (Get-Command $newProcess.Name -ErrorAction Stop).Path
                                    $newProcess.Path = $processPath
                                }
                                catch {
                                    $newProcess.Path = $newProcess.Name
                                }
                            }

                            Write-Host "Attempting to start process: $($newProcess.Path)" -ForegroundColor Cyan

                            $processArgs = @{
                                FilePath    = $newProcess.Path
                                PassThru    = $true
                                ErrorAction = "Stop"
                            }

                            if ($newProcess.Arguments) {
                                $processArgs.ArgumentList = $newProcess.Arguments
                            }

                            $process = Start-Process @processArgs

                            if ($process) {
                                $newProcess.Id = $process.Id
            
                                $jsonData = Get-Json | ConvertFrom-Json
                                $jsonData += $newProcess
            
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
                    } default {
                        Send-StaticFile -LocalPath $url.LocalPath -Response $response
                        break
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
    
    $script:shuttingDown = $true
    
    if (-not $Force) {
        Write-Host "Waiting for current requests to complete..."
        Start-Sleep -Seconds 3
    }
    
    if ($Listener) {
        $Listener.Stop()
        $Listener.Close()
    }
    else {
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
    
    $uptime = (Get-Date) - $script:serverStartTime
    Write-Host "Server stopped. Total uptime: $($uptime.ToString())"
    Write-Host "Total requests served: $script:requestCount"
}

Write-Host "Starting server..."
Write-Host "Press Ctrl+C to stop the server"

try {
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
        Write-Host "`nStopping server due to Ctrl+C..." -ForegroundColor Yellow
        $script:shuttingDown = $true
        $event.MessageData.Set()
        $event.Cancel = $true
    } -MessageData ([Threading.ManualResetEvent]::new($false))
    
    Start-Server
}
finally {
    Get-EventSubscriber | Where-Object SourceObject -eq ([Console]) | Unregister-Event
}