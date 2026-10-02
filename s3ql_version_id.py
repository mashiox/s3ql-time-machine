#!/usr/bin/env python3
"""
S3QL Version Identification Script
Retrieves and decodes the metadata headers of `s3ql_metadata` from S3
to determine the legacy filesystem revision and associated S3QL version.
"""
import sys
import boto3
import urllib.parse
import pickle
import base64
import ast

REV_VER_MAP = {
    25: '4.0.0',
    24: '3.8.1',
    23: '2.26',
    22: '2.16',
    21: '2.13',
    20: '2.9',
    16: '1.15',
    15: '1.10',
    14: '1.8.1',
    13: '1.6',
    12: '1.3',
    11: '1.0.1',
}

def identify_version(bucket_name, object_key="s3ql_metadata"):
    print(f"Inspecting s3://{bucket_name}/{object_key} for legacy S3QL version...")
    s3 = boto3.client('s3')
    
    try:
        response = s3.head_object(Bucket=bucket_name, Key=object_key)
    except Exception as e:
        print(f"Error fetching object headers: {e}")
        sys.exit(1)
        
    metadata = response.get('Metadata', {})
    
    # S3QL stores its metadata in x-amz-meta-meta-NNN headers.
    # boto3 automatically strips the 'x-amz-meta-' prefix, so the keys will appear as '000', '001', 'format', etc.
    if '000' not in metadata and 'meta-000' not in metadata and 'format' not in metadata and 'meta-format' not in metadata:
        print("No S3QL meta headers found. Is this a valid S3QL bucket?")
        print(f"Raw metadata keys returned by boto3: {list(metadata.keys())}")
        sys.exit(1)
        
    meta_format = metadata.get('format', metadata.get('meta-format', 'raw'))
        
    # Reconstruct the concatenated string
    concatenated = ""
    for i in range(1000):
        key = f"{i:03d}"
        key_meta = f"meta-{i:03d}"
        
        if key in metadata:
            concatenated += metadata[key]
        elif key_meta in metadata:
            concatenated += metadata[key_meta]
        else:
            break
            
    # Unquote AFTER concatenation to avoid breaking split escape sequences (like %3D) across chunk boundaries
    concatenated = urllib.parse.unquote(concatenated)
            
    try:
        if meta_format == 'raw2':
            meta_dict = ast.literal_eval('{ %s }' % concatenated)
            fs_attrs = {}
            for k, v in meta_dict.items():
                if isinstance(v, bytes):
                    try:
                        fs_attrs[k] = base64.b64decode(v)
                    except Exception:
                        fs_attrs[k] = None
                else:
                    fs_attrs[k] = v
        else:
            # Format 'raw' encodes the metadata dictionary with base64 and pickle
            padding = len(concatenated) % 4
            if padding:
                concatenated += '=' * (4 - padding)
            decoded = base64.b64decode(concatenated)
            fs_attrs = pickle.loads(decoded)
        
        print("Successfully extracted S3QL FsAttributes:")
        for k, v in fs_attrs.items():
            if k != 'data':
                print(f"  {k}: {v}")
                
        # Check if we can parse the revision directly
        if 'revision' in fs_attrs:
            rev = fs_attrs['revision']
            s3ql_version = REV_VER_MAP.get(rev, "Unknown")
            print(f"\n=> Detected S3QL Revision: {rev}")
            print(f"=> Corresponding S3QL Version: {s3ql_version}")
        else:
            print("\nRevision not found in cleartext headers. It is likely inside the encrypted 'data' field.")
            print("To proceed, spin up the S3QL Time Machine container with a suspected legacy S3QL version.")
            print("If it fails to mount, S3QL will reliably log 'File system revision too old: <revision>' to identify the version.")
            
    except Exception as e:
        print(f"Failed to decode S3QL metadata (format {meta_format}): {e}")
        print(f"DEBUG: Concatenated length: {len(concatenated)}")
        print(f"DEBUG: Head of string: {repr(concatenated[:100])}")
        print(f"DEBUG: Tail of string: {repr(concatenated[-100:])}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <bucket_name>")
        sys.exit(1)
    identify_version(sys.argv[1])
