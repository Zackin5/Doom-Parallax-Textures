
#define STEEP_PARALLAX
#define STEEP_PARALLAX_SMOOTH
#define PARALLAX_NORMALS    // Adds parallax displacement to normal maps
//#define DIFFUSE_LIGHTING    // Hackish diffuse lighting for walls

mat3 GetTBN();
vec3 GetBumpedNormal(mat3 tbn, vec2 texcoord);
vec2 ParallaxMap(mat3 tbn, out vec3 outNormal);
vec4 DiffuseLighting(vec4 color, vec3 normal);

Material ProcessMaterial()
{
    mat3 tbn = GetTBN();
    vec3 parallaxN;
    vec2 texCoord = ParallaxMap(tbn, parallaxN);

    Material material;
    material.Base = getTexel(texCoord);
    material.Normal = GetBumpedNormal(tbn, texCoord);
#ifdef PARALLAX_NORMALS
    material.Normal += parallaxN * material.Base.a;
#endif
#ifdef DIFFUSE_LIGHTING
    material.Base = DiffuseLighting(material.Base, material.Normal);
#endif

#if defined(SPECULAR)
    material.Specular = texture(speculartexture, texCoord).rgb;
    material.Glossiness = uSpecularMaterial.x;
    material.SpecularLevel = uSpecularMaterial.y;
#endif
#if defined(PBR)
    material.Metallic = texture(metallictexture, texCoord).r;
    material.Roughness = texture(roughnesstexture, texCoord).r;
    material.AO = texture(aotexture, texCoord).r;
#endif
#if defined(BRIGHTMAP)
    material.Bright = texture(brighttexture, texCoord);
#endif
    return material;
}

// Tangent/bitangent/normal space to world space transform matrix
mat3 GetTBN()
{
    vec3 n = normalize(vWorldNormal.xyz);
    vec3 p = pixelpos.xyz;
    vec2 uv = vTexCoord.st;

    // get edge vectors of the pixel triangle
    vec3 dp1 = dFdx(p);
    vec3 dp2 = dFdy(p);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);

    // solve the linear system
    vec3 dp2perp = cross(n, dp2); // cross(dp2, n);
    vec3 dp1perp = cross(dp1, n); // cross(n, dp1);
    vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;

    // construct a scale-invariant frame
    float invmax = inversesqrt(max(dot(t,t), dot(b,b)));
    return mat3(t * invmax, b * invmax, n);
}

vec3 GetBumpedNormal(mat3 tbn, vec2 texcoord)
{
#if defined(NORMALMAP)
    vec3 map = texture(normaltexture, texcoord).xyz;
    map = map * 255./127. - 128./127.; // Math so "odd" because 0.5 cannot be precisely described in an unsigned format
    map.xy *= vec2(0.5, -0.5); // Make normal map less strong and flip Y
    return normalize(tbn * map);
#else
    // Normal map load hack because for some reason the shader isn't being passed NORMALMAP?
    #if defined(normal)
        vec3 map = texture(normal, texcoord).xyz;
        map = map * 255./127. - 128./127.; // Math so "odd" because 0.5 cannot be precisely described in an unsigned format
        map.xy *= vec2(0.5, -0.5); // Make normal map less strong and flip Y
        return normalize(tbn * map);
    #else

    return normalize(vWorldNormal.xyz);
#endif
#endif
}

float GetDisplacementAt(vec2 currentTexCoords)
{
    return 0.5 - texture(displacement, currentTexCoords).r;
}

#ifndef STEEP_PARALLAX
    vec2 ParallaxMap(mat3 tbn, out vec3 outNormal)
    {
        outNormal = vec3(0,0,0);
        const float parallaxScale = 0.15;    // Default 0.15

        // Calculate fragment view direction in tangent space
        mat3 invTBN = transpose(tbn);
        vec3 V = normalize(invTBN * (uCameraPos.xyz - pixelpos.xyz));

        vec2 texCoords = vTexCoord.st;
        vec2 p = V.xy / abs(V.z) * GetDisplacementAt(texCoords) * parallaxScale;
        return texCoords - p;
    }
#else
    vec2 ParallaxMap(mat3 tbn, out vec3 outNormal)
    {
        const float parallaxScale = 0.3;    // Default 0.2
        const float minLayers = 8.0;
        const float maxLayers = 16.0;

        // Calculate fragment view direction in tangent space
        mat3 invTBN = transpose(tbn);
        vec3 V = normalize(invTBN * (uCameraPos.xyz - pixelpos.xyz));
        vec2 T = vTexCoord.st;

        float numLayers = mix(maxLayers, minLayers, clamp(abs(V.z), 0.0, 1.0)); // clamp is required due to precision loss

        // calculate the size of each layer
        float layerDepth = 1.0 / numLayers;

        // depth of current layer
        float currentLayerDepth = 0.0;

        // the amount to shift the texture coordinates per layer (from vector P)
        vec2 P = V.xy * parallaxScale;
        vec2 deltaTexCoords = P / numLayers;
        vec2 currentTexCoords = T;
        float currentDepthMapValue = GetDisplacementAt(currentTexCoords);

        while (currentLayerDepth < currentDepthMapValue)
        {
            // shift texture coordinates along direction of P
            currentTexCoords -= deltaTexCoords;

            // get depthmap value at current texture coordinates
            currentDepthMapValue = GetDisplacementAt(currentTexCoords);

            // get depth of next layer
            currentLayerDepth += layerDepth;
        }

        // get texture coordinates before collision (reverse operations)
        vec2 prevTexCoords = currentTexCoords + deltaTexCoords;

        // get depth after and before collision for linear interpolation
        float afterDepth  = currentDepthMapValue - currentLayerDepth;
        float beforeDepth = GetDisplacementAt(prevTexCoords) - currentLayerDepth + layerDepth;

        // calculate parallax normal
        outNormal = V * (afterDepth - beforeDepth);

        #ifndef STEEP_PARALLAX_SMOOTH            
            // interpolation of texture coordinates
            float weight = afterDepth / (afterDepth - beforeDepth);
            return prevTexCoords * weight + currentTexCoords * (1.0 - weight);
        #else
            const int _reliefSteps = 14;
            int currentStep = _reliefSteps;
            float smoothDelta = 0.5;
            while (currentStep > 0) {
            float currentGetDisplacementAt = GetDisplacementAt(currentTexCoords);
                deltaTexCoords *= 0.5;
                layerDepth *= 0.5;

                if (currentGetDisplacementAt > currentLayerDepth) {
                    currentTexCoords -= deltaTexCoords;
                    currentLayerDepth += layerDepth;
                    smoothDelta -= 0.1;
                }

                else {
                    currentTexCoords += deltaTexCoords;
                    currentLayerDepth -= layerDepth;
                    smoothDelta += 0.1;
                }
                currentStep--;
            }

            return currentTexCoords - (P * 0.01);
        #endif
    }
#endif

vec4 DiffuseLighting(vec4 color, vec3 normal)
{
    const vec3 lightColor = vec3(1,1,1);
    const vec3 lightDir = vec3(0,1,0);
    float diff = dot(normal, lightDir);
    // diff = pow(abs(diff), 1.0/3.0);
    // if(diff > 0.75)
        // return color;
    diff = clamp(diff, 0, 1);
    color.rgb += lightColor * diff;
    return color;
}