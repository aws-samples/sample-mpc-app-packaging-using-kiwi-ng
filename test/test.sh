# KMS Key ID
# nosemgrep: generic-api-key
KMS_KEY_ID=<replace-with-your-aws-kms-key-id>

echo "Step 1: Generating data key from KMS..."
# Generate data key from KMS
datakey_response=$(aws kms generate-data-key \
    --key-id "$KMS_KEY_ID" \
    --key-spec AES_256)
echo "✓ Data key generated"

echo "Step 2: Extracting keys and creating sample file..."
# Extract plaintext and encrypted data key
plaintext_key=$(echo "$datakey_response" | jq -r '.Plaintext' | base64 --decode)
encrypted_key=$(echo "$datakey_response" | jq -r '.CiphertextBlob')

# Create sample file with "hello world"
echo "hello world" > sample.txt
echo "✓ Sample file created"

echo "Step 3: Encrypting file with data key..."
# Generate and store IV
iv=$(openssl rand -hex 16)
echo "$iv" > sample.txt.iv

# Encrypt file using data key
openssl enc -aes-256-cbc \
    -in sample.txt \
    -out sample.txt.enc \
    -K $(xxd -p -c 64 <<< "$plaintext_key") \
    -iv "$iv"
echo "✓ File encrypted"

# Store encrypted data key in binary
echo "$encrypted_key" | base64 -d > datakey.enc
echo "✓ Encrypted data key stored"

# Clean up plaintext key from memory
unset plaintext_key

echo "Step 4: Generating RSA key pair for attestation..."
private_key="$(openssl genrsa | base64 --wrap 0)"
public_key="$(openssl rsa \
    -pubout \
    -in <(base64 --decode <<< "$private_key") \
    -outform DER \
    2> /dev/null \
    | base64 --wrap 0)"
echo "✓ RSA key pair generated"

echo "Step 5: Creating attestation document..."
# Create temporary file instead of process substitution
temp_key_file=$(mktemp)
base64 --decode <<< "$public_key" > "$temp_key_file"

attestation_doc="$(sudo nitro-tpm-attest \
    --public-key "$temp_key_file" \
    | base64 --wrap 0)"

# Cleanup
rm "$temp_key_file"
echo "✓ Attestation document created"


echo "Step 6: Decrypting data key with KMS using attestation..."
plaintext_cms=$(aws kms decrypt \
    --key-id "$KMS_KEY_ID" \
    --recipient "KeyEncryptionAlgorithm=RSAES_OAEP_SHA_256,AttestationDocument=$attestation_doc" \
    --ciphertext-blob fileb://datakey.enc \
    --output text \
    --query CiphertextForRecipient)
echo "✓ KMS decrypt successful"

# CiphertextForRecipient is encrypted using the public_key by KMS, decrypt is using th
# private_key


echo "Step 7: Decrypting CMS envelope with private key..."
return_datakey=$(openssl cms \
    -decrypt \
    -inkey <(base64 --decode <<< "$private_key") \
    -inform DER \
    -in <(base64 --decode <<< "$plaintext_cms"))
echo "✓ Data key recovered"

echo "Step 8: Decrypting original file with recovered data key..."
# Read the stored IV
iv=$(cat sample.txt.iv)

# Decrypt file using returned data key (remove any newlines from key)
return_datakey_clean=$(echo -n "$return_datakey")
openssl enc -d -aes-256-cbc \
    -in sample.txt.enc \
    -K $(xxd -p -c 64 <<< "$return_datakey_clean") \
    -iv "$iv"
echo "✓ File decryption complete - End-to-End test successful!"

