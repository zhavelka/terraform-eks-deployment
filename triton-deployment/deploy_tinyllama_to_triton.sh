#!/bin/bash
# deploy_tinyllama_to_triton.sh
# Quick script to deploy TinyLlama to Triton

MODEL_NAME="tinyllama"
S3_BUCKET="triton-gpu-cluster-triton-models-069435869585"

echo "Creating TinyLlama model for Triton..."

# Create directory structure
mkdir -p ${MODEL_NAME}/1

# Create config.pbtxt
cat > ${MODEL_NAME}/config.pbtxt << 'EOF'
name: "tinyllama"
backend: "python"
max_batch_size: 1

input [
  {
    name: "text_input"
    data_type: TYPE_STRING
    dims: [ -1 ]
  },
  {
    name: "max_tokens"
    data_type: TYPE_INT32
    dims: [ -1 ]
  },
  {
    name: "temperature"
    data_type: TYPE_FP32
    dims: [ -1 ]
  }
]

output [
  {
    name: "text_output"
    data_type: TYPE_STRING
    dims: [ -1 ]
  }
]

instance_group [
  {
    count: 1
    kind: KIND_GPU
    gpus: [ 0 ]
  }
]

parameters: {
  key: "FORCE_CPU_ONLY_INPUT_TENSORS"
  value: {
    string_value: "yes"
  }
}
EOF

# Create model.py
cat > ${MODEL_NAME}/1/model.py << 'EOF'
import json
import numpy as np
import triton_python_backend_utils as pb_utils
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
import os

class TritonPythonModel:
    def initialize(self, args):
        self.model_config = json.loads(args["model_config"])
        
        # Using TinyLlama - a small 1.1B parameter model that fits on T4 GPU
        model_id = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
        
        print(f"Loading model: {model_id}")
        
        # Set cache directory to avoid re-downloading
        cache_dir = "/tmp/model_cache"
        os.makedirs(cache_dir, exist_ok=True)
        
        # Load tokenizer and model
        self.tokenizer = AutoTokenizer.from_pretrained(model_id, cache_dir=cache_dir)
        self.tokenizer.pad_token = self.tokenizer.eos_token
        
        self.model = AutoModelForCausalLM.from_pretrained(
            model_id,
            torch_dtype=torch.float16,
            device_map="auto",
            cache_dir=cache_dir
        )
        self.model.eval()
        
        print("Model loaded successfully")

    def execute(self, requests):
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
            formatted_prompt = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            
            # Tokenize
            inputs = self.tokenizer(formatted_prompt, return_tensors="pt", max_length=512, truncation=True)
            inputs = {k: v.to(self.model.device) for k, v in inputs.items()}
            
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
EOF

# Upload to S3
echo "Uploading to S3..."
aws s3 cp ${MODEL_NAME} s3://${S3_BUCKET}/models/${MODEL_NAME}/ --recursive

echo "Done! Model uploaded to S3."
echo ""
echo "To test the model:"
echo "1. Restart Triton pod: kubectl delete pod -n triton-inference -l app=triton-inference-server"
echo "2. Wait for pod to be ready: kubectl get pods -n triton-inference -w"
echo "3. Port forward: kubectl port-forward -n triton-inference svc/triton-inference-server 8000:8000"
echo "4. Test with curl:"
echo ""
cat << 'EOF'
curl -X POST http://localhost:8000/v2/models/tinyllama/infer \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [
      {
        "name": "text_input",
        "shape": [1, 1],
        "datatype": "BYTES",
        "data": ["Tell me a short story about a robot"]
      },
      {
        "name": "max_tokens",
        "shape": [1, 1],
        "datatype": "INT32",
        "data": [100]
      },
      {
        "name": "temperature",
        "shape": [1, 1],
        "datatype": "FP32",
        "data": [0.7]
      }
    ]
  }'
EOF