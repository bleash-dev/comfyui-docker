#!/usr/bin/env python3
"""
Multi-Tenant ComfyUI Management Server
Manages multiple ComfyUI instances for different users on the same host
"""

import http.server
import socketserver
import json
import subprocess
import os
import psutil
import time
import threading
import signal
import sys
import logging
import boto3
import socket
import requests
from pathlib import Path
from datetime import datetime
from typing import Dict, Optional, List

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/tenant_manager.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class ProcessManager:
    """Manages ComfyUI processes for different tenants"""
    
    def __init__(self):
        self.processes_file = "/tmp/comfyui_processes.json"
        self.processes: Dict[str, dict] = {}
        self.load_processes()
        
    def load_processes(self):
        """Load process information from file"""
        try:
            if os.path.exists(self.processes_file):
                with open(self.processes_file, 'r') as f:
                    self.processes = json.load(f)
                # Verify processes are still running
                self._cleanup_dead_processes()
        except Exception as e:
            logger.error(f"Error loading processes: {e}")
            self.processes = {}
    
    def save_processes(self):
        """Save process information to file"""
        try:
            with open(self.processes_file, 'w') as f:
                json.dump(self.processes, f, indent=2)
        except Exception as e:
            logger.error(f"Error saving processes: {e}")
    
    def _is_port_open(self, host: str, port: int, timeout: float = 3.0) -> bool:
        """Check if a port is open and accepting connections"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            result = sock.connect_ex((host, port))
            sock.close()
            return result == 0
        except Exception:
            return False
    
    def _is_comfyui_healthy(self, port: int, timeout: float = 5.0) -> bool:
        """Check if ComfyUI service is healthy on the given port"""
        try:
            # First check if port is open
            if not self._is_port_open('localhost', port, timeout=2.0):
                return False
            
            # Try to reach ComfyUI's health endpoint or main page
            url = f"http://localhost:{port}"
            response = requests.get(url, timeout=timeout)
            # ComfyUI typically returns 200 for the main page
            return response.status_code == 200
        except Exception:
            return False
    
    def _force_cleanup_tenant(self, pod_id: str, process_info: dict):
        """Force cleanup of a tenant that's not responding properly"""
        try:
            pid = process_info.get('pid')
            if pid and psutil.pid_exists(pid):
                try:
                    # Try graceful shutdown first
                    os.killpg(os.getpgid(pid), signal.SIGTERM)
                    time.sleep(2)
                    
                    # Force kill if still running
                    if psutil.pid_exists(pid):
                        os.killpg(os.getpgid(pid), signal.SIGKILL)
                        time.sleep(1)
                except ProcessLookupError:
                    pass  # Process already dead
            
            # Remove from tracking
            if pod_id in self.processes:
                del self.processes[pod_id]
                self.save_processes()
                logger.info(f"Force cleaned up tenant {pod_id}")
        except Exception as e:
            logger.error(f"Error force cleaning tenant {pod_id}: {e}")
    
    def _cleanup_dead_processes(self):
        """Remove dead processes from tracking"""
        dead_pods = []
        for pod_id, info in self.processes.items():
            pid = info.get('pid')
            if pid and not psutil.pid_exists(pid):
                dead_pods.append(pod_id)
        
        for pod_id in dead_pods:
            del self.processes[pod_id]
            logger.info(f"Cleaned up dead process for pod {pod_id}")
        
        if dead_pods:
            self.save_processes()
    
    def start_tenant(self, pod_id: str, username: str, port: int,
                     env_vars: dict) -> dict:
        """Start a ComfyUI instance for a tenant"""
        try:
            # Check if already running with proper health check
            if pod_id in self.processes:
                existing_info = self.processes[pod_id]
                existing_pid = existing_info.get('pid', 0)
                existing_port = existing_info.get('port')
                
                # Check if process exists AND service is healthy on the port
                if (psutil.pid_exists(existing_pid) and
                        existing_port and
                        self._is_comfyui_healthy(existing_port)):
                    logger.info(f"Tenant {pod_id} already running healthy "
                                f"on port {existing_port}")
                    return {
                        "status": "already_running",
                        "port": existing_port,
                        "pid": existing_pid,
                        "healthy": True
                    }
                else:
                    # Process exists but service is not healthy, clean it up
                    logger.warning(f"Tenant {pod_id} process exists but "
                                   f"service unhealthy, cleaning up...")
                    self._force_cleanup_tenant(pod_id, existing_info)
            
            # Setup environment
            network_volume = env_vars.get(
                'NETWORK_VOLUME', f'/workspace/{pod_id}'
            )
            os.makedirs(network_volume, exist_ok=True)
            
            # Setup tenant-specific environment
            tenant_env = os.environ.copy()
            tenant_env.update({
                'POD_ID': pod_id,
                'POD_USER_NAME': username,
                'NETWORK_VOLUME': network_volume,
                'COMFYUI_PORT': str(port),
                **env_vars
            })
            
            # Create symlinks to scripts if needed
            self._setup_tenant_scripts(network_volume)
            
            # Start the ComfyUI process
            cmd = ['/bin/bash', '/scripts/start_tenant.sh']
            process = subprocess.Popen(
                cmd,
                env=tenant_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid  # Create new process group
            )
            
            # Store process information
            process_info = {
                'pid': process.pid,
                'port': port,
                'username': username,
                'network_volume': network_volume,
                'started_at': time.time(),
                'env': env_vars
            }
            
            self.processes[pod_id] = process_info
            self.save_processes()
            
            # Setup CloudWatch logging for this tenant
            self._setup_cloudwatch_logging(pod_id, network_volume)
            
            logger.info(f"Started tenant {pod_id} for user {username} "
                        f"on port {port} with PID {process.pid}")
            
            return {
                "status": "started",
                "port": port,
                "pid": process.pid,
                "network_volume": network_volume
            }
            
        except Exception as e:
            logger.error(f"Error starting tenant {pod_id}: {e}")
            raise
    
    def stop_tenant(self, pod_id: str) -> dict:
        """Stop a ComfyUI instance for a tenant"""
        try:
            if pod_id not in self.processes:
                return {"status": "not_found"}
            
            process_info = self.processes[pod_id]
            pid = process_info.get('pid')
            
            if not pid or not psutil.pid_exists(pid):
                del self.processes[pod_id]
                self.save_processes()
                return {"status": "not_running"}
            
            # Try graceful shutdown first
            try:
                os.killpg(os.getpgid(pid), signal.SIGTERM)
                # Wait for graceful shutdown
                for _ in range(30):  # Wait up to 30 seconds
                    if not psutil.pid_exists(pid):
                        break
                    time.sleep(1)
                
                # Force kill if still running
                if psutil.pid_exists(pid):
                    os.killpg(os.getpgid(pid), signal.SIGKILL)
                    time.sleep(2)
                
            except ProcessLookupError:
                pass  # Process already dead
            
            # Clean up
            del self.processes[pod_id]
            self.save_processes()
            
            logger.info(f"Stopped tenant {pod_id} with PID {pid}")
            
            return {"status": "stopped"}
            
        except Exception as e:
            logger.error(f"Error stopping tenant {pod_id}: {e}")
            raise
    
    def get_tenant_info(self) -> List[dict]:
        """Get information about all running tenants"""
        self._cleanup_dead_processes()
        
        tenants = []
        for pod_id, info in self.processes.items():
            pid = info.get('pid', 0)
            port = info.get('port')
            is_process_alive = psutil.pid_exists(pid)
            is_service_healthy = (port and
                                  self._is_comfyui_healthy(port)
                                  if is_process_alive else False)
            
            # Determine status based on both process and service health
            if is_process_alive and is_service_healthy:
                status = "healthy"
            elif is_process_alive and not is_service_healthy:
                status = "unhealthy"
            else:
                status = "dead"
            
            tenant_info = {
                "pod_id": pod_id,
                "username": info.get('username'),
                "port": port,
                "pid": pid,
                "uptime": time.time() - info.get('started_at', 0),
                "network_volume": info.get('network_volume'),
                "status": status,
                "process_alive": is_process_alive,
                "service_healthy": is_service_healthy
            }
            tenants.append(tenant_info)
        
        return tenants
    
    def _setup_tenant_scripts(self, network_volume: str):
        """Setup scripts and symlinks for tenant"""
        scripts_dir = os.path.join(network_volume, 'scripts')
        os.makedirs(scripts_dir, exist_ok=True)
        
        # Create symlinks to shared scripts
        source_scripts_dir = '/scripts'
        for script_file in os.listdir(source_scripts_dir):
            if script_file.endswith('.sh'):
                source_path = os.path.join(source_scripts_dir, script_file)
                target_path = os.path.join(scripts_dir, script_file)
                
                if not os.path.exists(target_path):
                    try:
                        os.symlink(source_path, target_path)
                    except OSError:
                        # Fallback to copy if symlink fails
                        subprocess.run(['cp', source_path, target_path])
    
    def _setup_cloudwatch_logging(self, pod_id: str, network_volume: str):
        """Setup CloudWatch logging for tenant"""
        try:
            logger.info(f"Setting up CloudWatch logging for pod {pod_id}")
            
            # Create log directory
            log_dir = os.path.join(network_volume, 'logs')
            os.makedirs(log_dir, exist_ok=True)
            
            # Run the pod-specific CloudWatch setup script
            setup_script = '/scripts/setup_pod_cloudwatch.sh'
            if os.path.exists(setup_script):
                result = subprocess.run(
                    [setup_script, pod_id],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                if result.returncode == 0:
                    logger.info(f"CloudWatch logging configured for "
                                f"pod {pod_id}")
                else:
                    logger.warning(f"CloudWatch setup failed for "
                                   f"pod {pod_id}: {result.stderr}")
            else:
                logger.warning(f"CloudWatch setup script not found: "
                               f"{setup_script}")
                
        except Exception as e:
            logger.error(f"Error setting up CloudWatch logging for "
                         f"pod {pod_id}: {e}")
            # 2. Configure log streams for different log files
            # 3. Set up log forwarding agents
            
        except Exception as e:
            logger.error(f"Error setting up CloudWatch logging for "
                         f"{pod_id}: {e}")


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for tenant management and metrics"""
    
    def __init__(self, *args, process_manager=None, **kwargs):
        self.process_manager = process_manager
        super().__init__(*args, **kwargs)
    
    def log_message(self, format, *args):
        """Override to use our logger"""
        logger.info(f"{self.client_address[0]} - {format % args}")
    
    def do_GET(self):
        if self.path == '/health':
            self.send_health_response()
        elif self.path == '/metrics':
            self.send_metrics_response()
        elif self.path == '/tenants':
            self.send_tenants_response()
        else:
            self.send_error(404)
    
    def do_POST(self):
        if self.path == '/start':
            self.handle_start_request()
        elif self.path == '/stop':
            self.handle_stop_request()
        elif self.path == '/execute':
            self.handle_execute_request()
        else:
            self.send_error(404)
    
    def send_health_response(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        health_data = {
            "status": "healthy",
            "timestamp": time.time(),
            "uptime": self.get_uptime(),
            "services": self.check_services_health()
        }
        self.wfile.write(json.dumps(health_data).encode())
    
    def send_metrics_response(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        metrics_data = {
            "timestamp": time.time(),
            "system": self.get_system_metrics(),
            "disk_space": self.get_disk_space_metrics(),
            "gpu": self.get_gpu_metrics(),
            "performance": self.get_performance_metrics(),
            "tenants": self.get_tenant_info()
        }
        self.wfile.write(json.dumps(metrics_data).encode())
    
    def send_tenants_response(self):
        """Send response with current tenant information including podIds"""
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        # Get tenant info directly from process manager
        tenant_list = self.process_manager.get_tenant_info()
        
        tenants_data = {
            "timestamp": time.time(),
            "tenants": tenant_list,
            "summary": {
                "total_tenants": len(tenant_list),
                "healthy_tenants": len([
                    t for t in tenant_list
                    if t['status'] == 'healthy'
                ]),
                "unhealthy_tenants": len([
                    t for t in tenant_list
                    if t['status'] == 'unhealthy'
                ]),
                "dead_tenants": len([
                    t for t in tenant_list
                    if t['status'] == 'dead'
                ])
            }
        }
        self.wfile.write(json.dumps(tenants_data).encode())
    
    def handle_start_request(self):
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            pod_id = data.get('POD_ID')
            username = data.get('POD_USERNAME')
            port = data.get('PORT')
            env_vars = data.get('env', {})
            
            if not all([pod_id, username, port]):
                self.send_error(400, "POD_ID, POD_USERNAME, and PORT required")
                return
            
            # Start the tenant
            result = self.process_manager.start_tenant(
                pod_id, username, port, env_vars)
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
            
        except Exception as e:
            logger.error(f"Error in start request: {e}")
            self.send_error(500, str(e))
    
    def handle_stop_request(self):
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            pod_id = data.get('POD_ID')
            if not pod_id:
                self.send_error(400, "POD_ID required")
                return
            
            # Stop the tenant
            result = self.process_manager.stop_tenant(pod_id)
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
            
        except Exception as e:
            logger.error(f"Error in stop request: {e}")
            self.send_error(500, str(e))
    
    def handle_execute_request(self):
        try:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            
            command = data.get('command')
            if not command:
                self.send_error(400, "command required")
                return
            
            # Execute the command
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=300  # 5 minute timeout
            )
            
            self.send_response(200 if result.returncode == 0 else 500)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            response = {
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "success": result.returncode == 0
            }
            self.wfile.write(json.dumps(response).encode())
            
        except subprocess.TimeoutExpired:
            self.send_error(408, "Command timeout")
        except Exception as e:
            logger.error(f"Error in execute request: {e}")
            self.send_error(500, str(e))
    
    def get_uptime(self):
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.readline().split()[0])
            return uptime_seconds
        except Exception:
            return 0
    
    def check_services_health(self):
        services = {}
        try:
            # Check basic system health
            services['disk_usage'] = psutil.disk_usage('/').percent
            services['memory_usage'] = psutil.virtual_memory().percent
            services['cpu_count'] = psutil.cpu_count()
            
            # Check tenant processes
            tenants = self.process_manager.get_tenant_info()
            services['active_tenants'] = len([
                t for t in tenants if t['status'] in ['healthy', 'running']])
            services['total_tenants'] = len(tenants)
            
        except Exception as e:
            services['error'] = str(e)
        
        return services
    
    def get_system_metrics(self):
        try:
            # CPU and Memory
            cpu_percent = psutil.cpu_percent(interval=1)
            memory = psutil.virtual_memory()
            disk = psutil.disk_usage('/')
            
            return {
                "cpu_percent": cpu_percent,
                "cpu_count": psutil.cpu_count(),
                "memory_percent": memory.percent,
                "memory_total_gb": round(memory.total / (1024**3), 2),
                "memory_used_gb": round(memory.used / (1024**3), 2),
                "memory_available_gb": round(memory.available / (1024**3), 2),
                "disk_percent": disk.percent,
                "disk_total_gb": round(disk.total / (1024**3), 2),
                "disk_used_gb": round(disk.used / (1024**3), 2),
                "disk_free_gb": round(disk.free / (1024**3), 2),
                "load_average": os.getloadavg(),
                "boot_time": psutil.boot_time(),
            }
        except Exception as e:
            return {"error": str(e)}
    
    def get_gpu_metrics(self):
        try:
            # Try to get NVIDIA GPU metrics
            result = subprocess.run([
                'nvidia-smi',
                '--query-gpu=index,name,utilization.gpu,utilization.memory,' +
                'temperature.gpu,memory.total,memory.used,memory.free,' +
                'power.draw,power.limit',
                '--format=csv,noheader,nounits'
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                lines = result.stdout.strip().split('\n')
                gpus = []
                
                for line in lines:
                    if line.strip():
                        values = [v.strip() for v in line.split(',')]
                        if len(values) >= 10:
                            # Helper function to safely convert values
                            def safe_float(val):
                                return float(val) if val != 'N/A' else 0
                            
                            def safe_int(val):
                                return int(val) if val != 'N/A' else 0
                            
                            gpus.append({
                                "index": safe_int(values[0]),
                                "name": values[1],
                                "utilization_percent": safe_float(values[2]),
                                "memory_utilization_percent": safe_float(
                                    values[3]),
                                "temperature": safe_float(values[4]),
                                "memory_total_mb": safe_float(values[5]),
                                "memory_used_mb": safe_float(values[6]),
                                "memory_free_mb": safe_float(values[7]),
                                "power_draw_w": safe_float(values[8]),
                                "power_limit_w": safe_float(values[9]),
                            })
                
                # Return aggregated metrics for all GPUs
                if gpus:
                    total_mem = sum(gpu["memory_total_mb"] for gpu in gpus)
                    used_mem = sum(gpu["memory_used_mb"] for gpu in gpus)
                    free_mem = sum(gpu["memory_free_mb"] for gpu in gpus)
                    avg_util = sum(gpu["utilization_percent"] for gpu in gpus)
                    avg_mem_util = sum(
                        gpu["memory_utilization_percent"] for gpu in gpus)
                    avg_temp = sum(gpu["temperature"] for gpu in gpus)
                    total_power = sum(gpu["power_draw_w"] for gpu in gpus)
                    
                    return {
                        "gpu_count": len(gpus),
                        "total_memory_gb": round(total_mem / 1024, 2),
                        "used_memory_gb": round(used_mem / 1024, 2),
                        "free_memory_gb": round(free_mem / 1024, 2),
                        "avg_utilization_percent": round(
                            avg_util / len(gpus), 1),
                        "avg_memory_utilization_percent": round(
                            avg_mem_util / len(gpus), 1),
                        "avg_temperature": round(avg_temp / len(gpus), 1),
                        "total_power_draw_w": round(total_power, 1),
                        "individual_gpus": gpus
                    }
            
            return {"error": "No GPU metrics available"}
        except Exception as e:
            return {"error": str(e)}
    
    def get_disk_space_metrics(self):
        """Get disk space metrics focused on /workspace/ tenant data."""
        try:
            disk_metrics = {}
            
            # Overall disk usage for the main filesystem
            try:
                root_usage = psutil.disk_usage('/')
                disk_metrics["total_gb"] = round(
                    root_usage.total / (1024**3), 2)
                disk_metrics["used_gb"] = round(
                    root_usage.used / (1024**3), 2)
                disk_metrics["free_gb"] = round(
                    root_usage.free / (1024**3), 2)
                used_pct = (root_usage.used / root_usage.total) * 100
                disk_metrics["used_percent"] = round(used_pct, 1)
            except Exception as e:
                disk_metrics["error"] = (
                    f"Failed to get root disk usage: {str(e)}")
            
            # Workspace directory usage (where all tenant data is stored)
            workspace_path = "/workspace"
            try:
                if os.path.exists(workspace_path):
                    # Get workspace size using du command for accuracy
                    result = subprocess.run(
                        ['du', '-sb', workspace_path],
                        capture_output=True, text=True, timeout=10
                    )
                    if result.returncode == 0:
                        size_bytes = int(result.stdout.split()[0])
                        disk_metrics["workspace"] = {
                            "path": workspace_path,
                            "size_gb": round(size_bytes / (1024**3), 2),
                            "size_mb": round(size_bytes / (1024**2), 1),
                            "exists": True
                        }
                    else:
                        disk_metrics["workspace"] = {
                            "path": workspace_path,
                            "exists": True,
                            "error": "Failed to calculate size with du command"
                        }
                else:
                    disk_metrics["workspace"] = {
                        "path": workspace_path,
                        "exists": False
                    }
            except Exception as e:
                disk_metrics["workspace"] = {
                    "path": workspace_path,
                    "error": str(e),
                    "exists": False
                }
            
            # Add warnings for disk space
            warnings = []
            if "used_percent" in disk_metrics:
                if disk_metrics["used_percent"] > 90:
                    warnings.append("CRITICAL: Disk usage above 90%")
                elif disk_metrics["used_percent"] > 80:
                    warnings.append("WARNING: Disk usage above 80%")
                elif disk_metrics["used_percent"] > 70:
                    warnings.append("NOTICE: Disk usage above 70%")
            
            if warnings:
                disk_metrics["warnings"] = warnings
            
            return disk_metrics
            
        except Exception as e:
            return {"error": f"Failed to get disk space metrics: {str(e)}"}
    
    def get_performance_metrics(self):
        try:
            # Network I/O
            net_io = psutil.net_io_counters()
            
            # Disk I/O
            disk_io = psutil.disk_io_counters()
            
            return {
                "network_bytes_sent": net_io.bytes_sent,
                "network_bytes_recv": net_io.bytes_recv,
                "network_packets_sent": net_io.packets_sent,
                "network_packets_recv": net_io.packets_recv,
                "network_errin": net_io.errin,
                "network_errout": net_io.errout,
                "disk_read_bytes": disk_io.read_bytes if disk_io else 0,
                "disk_write_bytes": disk_io.write_bytes if disk_io else 0,
                "disk_read_count": disk_io.read_count if disk_io else 0,
                "disk_write_count": disk_io.write_count if disk_io else 0,
                "active_connections": len(psutil.net_connections()),
                "process_count": len(psutil.pids()),
            }
        except Exception as e:
            return {"error": str(e)}
    
    def get_tenant_info(self):
        try:
            return {
                "tenants": self.process_manager.get_tenant_info()
            }
        except Exception as e:
            return {"error": str(e)}


def create_handler_class(process_manager):
    """Create handler class with process manager dependency injection"""
    class Handler(MetricsHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, process_manager=process_manager, **kwargs)
    return Handler


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    logger.info(f"Received signal {signum}, shutting down...")
    sys.exit(0)


def main():
    """Main entry point"""
    # Setup signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # Initialize process manager
    process_manager = ProcessManager()
    
    # Create HTTP server
    PORT = 80
    Handler = create_handler_class(process_manager)
    
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        logger.info(
            f"Multi-tenant ComfyUI management server running on port {PORT}")
        
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            logger.info("Server interrupted by user")
        except Exception as e:
            logger.error(f"Server error: {e}")
        finally:
            logger.info("Server shutting down")


if __name__ == "__main__":
    main()
