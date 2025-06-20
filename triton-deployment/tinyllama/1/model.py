# model.py - Self-installing model for Triton
import json
import numpy as np
import triton_python_backend_utils as pb_utils
import subprocess
import sys
import os
import importlib

class TritonPythonModel:
    def initialize(self, args):
        self.model_config = json.loads(args["model_config"])
        
        # Install packages if needed
        self._install_dependencies()
        
        # Now import the packages
        import torch
        from transformers import AutoTokenizer, AutoModelForCausalLM
        
        # Load model
        model_id = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
        print(f"Loading model: {model_id}")
        
        cache_dir = "/tmp/model_cache"
        os.makedirs(cache_dir, exist_ok=True)
        
        self.tokenizer = AutoTokenizer.from_pretrained(model_id, cache_dir=cache_dir)
        self.tokenizer.pad_token = self.tokenizer.eos_token
        
        # Detect device
        if torch.cuda.is_available():
            self.device = "cuda"
            self.model = AutoModelForCausalLM.from_pretrained(
                model_id,
                torch_dtype=torch.float16,
                device_map="auto",
                cache_dir=cache_dir
            )
        else:
            self.device = "cpu"
            self.model = AutoModelForCausalLM.from_pretrained(
                model_id,
                torch_dtype=torch.float32,
                cache_dir=cache_dir
            )
        
        self.model.eval()
        print(f"Model loaded successfully on {self.device}")

    def _install_dependencies(self):
        """Install required packages if not present"""
        packages = [
            ('torch', 'torch==2.0.1', '--index-url', 'https://download.pytorch.org/whl/cu118'),
            ('transformers', 'transformers==4.35.2'),
            ('accelerate', 'accelerate==0.25.0'),
            ('sentencepiece', 'sentencepiece==0.1.99')
        ]
        
        for package_info in packages:
            module_name = package_info[0]
            try:
                importlib.import_module(module_name)
                print(f"{module_name} already installed")
            except ImportError:
                print(f"Installing {module_name}...")
                install_cmd = [sys.executable, "-m", "pip", "install"]
                install_cmd.extend(package_info[1:])
                install_cmd.extend(["--no-cache-dir", "--timeout", "1000"])
                
                max_retries = 3
                for attempt in range(max_retries):
                    try:
                        subprocess.check_call(install_cmd)
                        print(f"{module_name} installed successfully")
                        break
                    except subprocess.CalledProcessError as e:
                        if attempt < max_retries - 1:
                            print(f"Installation failed, retrying... ({attempt + 1}/{max_retries})")
                            import time
                            time.sleep(10)
                        else:
                            print(f"Failed to install {module_name} after {max_retries} attempts")
                            raise e

    def execute(self, requests):
        import torch
        from transformers import AutoTokenizer, AutoModelForCausalLM
        
        responses = []
        
        for request in requests:
            # Get inputs
            text_input = pb_utils.get_input_tensor_by_name(request, "text_input").as_numpy()
            max_tokens = pb_utils.get_input_tensor_by_name(request, "max_tokens").as_numpy()
            temperature = pb_utils.get_input_tensor_by_name(request, "temperature").as_numpy()
            
            # Process input
            prompt = text_input[0][0].decode("utf-8")
            max_len = int(max_tokens[0][0])
            temp = float(temperature[0][0])
            
            # Apply chat template
            messages = [{"role": "user", "content": prompt}]
            formatted_prompt = self.tokenizer.apply_chat_template(
                messages, tokenize=False, add_generation_prompt=True
            )
            
            # Tokenize
            inputs = self.tokenizer(
                formatted_prompt, 
                return_tensors="pt", 
                max_length=512, 
                truncation=True
            )
            
            if self.device == "cuda":
                inputs = {k: v.cuda() for k, v in inputs.items()}
            
            # Generate
            with torch.no_grad():
                outputs = self.model.generate(
                    **inputs,
                    max_new_tokens=max_len,
                    temperature=temp if temp > 0 else 1e-7,
                    do_sample=temp > 0,
                    pad_token_id=self.tokenizer.pad_token_id,
                    eos_token_id=self.tokenizer.eos_token_id
                )
            
            # Decode only the generated part
            generated_ids = outputs[0][inputs["input_ids"].shape[1]:]
            output_text = self.tokenizer.decode(generated_ids, skip_special_tokens=True)
            
            # Create output tensor
            output_tensor = pb_utils.Tensor(
                "text_output",
                np.array([[output_text.encode("utf-8")]], dtype=object)
            )
            
            responses.append(pb_utils.InferenceResponse(output_tensors=[output_tensor]))
        
        return responses

    def finalize(self):
        print("Cleaning up...")
