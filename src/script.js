document.addEventListener('DOMContentLoaded', async () => {
    const stopProcessForm = document.getElementById('stopProcessForm');
    const addProcessForm = document.getElementById('addProcessForm');
    const processesContainer = document.getElementById('listProcesses');
    
    const date = new Date();
    const hour = date.getHours();

    async function fetchName() {
        try {
            const greeting = document.getElementById('greetings');
            if (!greeting) {
                console.error('greetings element not found');
                return;
            }
            
            const response = await fetch('http://localhost:2000/api/name');
            const data = await response.json();
            
            let greetingText;
            if (hour >= 6 && hour < 12) {
                greetingText = `Good morning, <span class="text-amber-500">${data.name}</span>!`;
            } else if (hour >= 12 && hour < 18) {
                greetingText = `Good afternoon, <span class="text-amber-500">${data.name}</span>!`;
            } else if (hour >= 18 && hour < 22) {
                greetingText = `Good evening, <span class="text-amber-500">${data.name}</span>!`;
            } else {
                greetingText = `Good night, <span class="text-amber-500">${data.name}</span>!`;
            }
            
            greeting.innerHTML = greetingText;
        } catch (error) {
            console.error('Error fetching user name:', error);
        }
    }

    async function handleProcess(action) {
        try {
            const inputElement = document.getElementById(`${action}ProcessInput`);
            if (!inputElement) {
                console.error(`${action}ProcessInput element not found`);
                return;
            }
            
            const input = inputElement.value.trim();
            if (!input) {
                alert(`Please enter a process ${action === 'add' ? 'to start' : 'to stop'}`);
                return;
            }
            
            const endpoint = action === 'add' ? 'http://localhost:2000/api/add' : 'http://localhost:2000/api/stop';
            const response = await fetch(endpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ Name: input })
            });
            
            const result = await response.json();
            
            getProcesses();
        } catch (error) {
            console.error(`Error ${action}ing process:`, error);
        }
    }

    async function getProcesses() {
        try {
            if (!processesContainer) {
                console.error('listProcesses element not found');
                return;
            }
            
            const response = await fetch('http://localhost:2000/api/processes');
            const data = await response.json();
            
            processesContainer.innerHTML = '';
            
            data.sort((a, b) => a.Name.localeCompare(b.Name));
            
            data.forEach((process) => {
                const memoryInMB = (process.Memory || 0).toFixed(2);
                const li = document.createElement('li');
                li.className = 'flex justify-between items-center py-2 border-b border-gray-700';
                
                li.innerHTML = `
                    <div class="flex items-center">
                        <span class="text-white">${process.Name}</span>
                        <span class="text-xs text-gray-400 ml-2">(PID: ${process.Id})</span>
                    </div>
                    <div class="flex items-center">
                        <span class="text-xs text-gray-400 mr-4">${memoryInMB} MB</span>
                        <button class="stop-btn px-2 py-1 bg-red-600 hover:bg-red-700 rounded text-xs" 
                                data-pid="${process.Id}" data-name="${process.Name}"></button>
                    </div>
                `;
                
                processesContainer.appendChild(li);
            });
            
            document.querySelectorAll('.stop-btn').forEach(btn => {
                btn.addEventListener('click', async () => {
                    const pid = btn.getAttribute('data-pid');
                    const processName = btn.getAttribute('data-name');
                    
                    try {
                        const response = await fetch('http://localhost:2000/api/stop', {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/json'
                            },
                            body: JSON.stringify({ Id: pid })
                        });
                        
                        const result = await response.json();
                        
                        if (result.success) {
                            alert(`Successfully stopped ${processName}`);
                            getProcesses(); // Refresh list
                        } else {
                            alert(`Error: ${result.error}`);
                        }
                    } catch (error) {
                        console.error('Error stopping process:', error);
                    }
                });
            });
        } catch (error) {
            console.error('Error getting processes:', error);
            processesContainer.innerHTML = '<li class="text-red-500">Error loading processes</li>';
        }
    }

    if (addProcessForm) {
        addProcessForm.addEventListener('submit', (e) => {
            e.preventDefault();
            handleProcess('add');
        });
    }

    if (stopProcessForm) {
        stopProcessForm.addEventListener('submit', (e) => {
            e.preventDefault();
            handleProcess('stop');
        });
    }

    await fetchName();
    await getProcesses();
});