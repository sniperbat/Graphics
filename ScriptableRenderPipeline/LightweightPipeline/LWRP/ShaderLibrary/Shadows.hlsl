#ifndef LIGHTWEIGHT_SHADOWS_INCLUDED
#define LIGHTWEIGHT_SHADOWS_INCLUDED

#include "CoreRP/ShaderLibrary/Common.hlsl"
#include "CoreRP/ShaderLibrary/Shadow/ShadowSamplingTent.hlsl"

#define MAX_SHADOW_CASCADES 4

///////////////////////////////////////////////////////////////////////////////
// Light Classification shadow defines                                       //
//                                                                           //
// In order to reduce shader variations main light keywords were combined    //
// here we define shadow keywords.                                           //
///////////////////////////////////////////////////////////////////////////////
#if defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW) || defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_CASCADE) || defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_SOFT) || defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_CASCADE_SOFT) || defined(_MAIN_LIGHT_SPOT_SHADOW) || defined(_MAIN_LIGHT_SPOT_SHADOW_SOFT)
    #define _SHADOWS_ENABLED
#endif

#if defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_SOFT) || defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_CASCADE_SOFT) || defined(_MAIN_LIGHT_SPOT_SHADOW_SOFT)
    #define _SHADOWS_SOFT
#endif

#if defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_CASCADE) || defined(_MAIN_LIGHT_DIRECTIONAL_SHADOW_CASCADE_SOFT)
    #define _SHADOWS_CASCADE
#endif

#if defined(_MAIN_LIGHT_SPOT_SHADOW) || defined(_MAIN_LIGHT_SPOT_SHADOW_SOFT)
    #define _SHADOWS_PERSPECTIVE
#endif

TEXTURE2D_SHADOW(_ShadowMap);
SAMPLER_CMP(sampler_ShadowMap);

CBUFFER_START(_ShadowBuffer)
// Last cascade is initialized with a no-op matrix. It always transforms
// shadow coord to half(0, 0, NEAR_PLANE). We use this trick to avoid
// branching since ComputeCascadeIndex can return cascade index = MAX_SHADOW_CASCADES
float4x4 _WorldToShadow[MAX_SHADOW_CASCADES + 1];
float4 _DirShadowSplitSpheres[MAX_SHADOW_CASCADES];
float4 _DirShadowSplitSphereRadii;
half4 _ShadowOffset0;
half4 _ShadowOffset1;
half4 _ShadowOffset2;
half4 _ShadowOffset3;
half4 _ShadowData; // (x: shadowStrength)
half4 _ShadowmapSize; // (xy: 1/width and 1/height, zw: width and height)
CBUFFER_END

inline half SampleShadowmap(half4 shadowCoord)
{
#if defined(_SHADOWS_PERSPECTIVE)
    shadowCoord.xyz = shadowCoord.xyz /= shadowCoord.w;
#endif

    half attenuation;

#ifdef _SHADOWS_SOFT
#ifdef SHADER_API_MOBILE
    // 4-tap hardware comparison
    half4 attenuation4;
    attenuation4.x = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz + _ShadowOffset0.xyz);
    attenuation4.y = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz + _ShadowOffset1.xyz);
    attenuation4.z = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz + _ShadowOffset2.xyz);
    attenuation4.w = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz + _ShadowOffset3.xyz);
    attenuation = dot(attenuation4, 0.25);
#else
    real fetchesWeights[9];
    real2 fetchesUV[9];
    SampleShadow_ComputeSamples_Tent_5x5(_ShadowmapSize, shadowCoord.xy, fetchesWeights, fetchesUV);

    attenuation  = fetchesWeights[0] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[0].xy, shadowCoord.z));
    attenuation += fetchesWeights[1] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[1].xy, shadowCoord.z));
    attenuation += fetchesWeights[2] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[2].xy, shadowCoord.z));
    attenuation += fetchesWeights[3] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[3].xy, shadowCoord.z));
    attenuation += fetchesWeights[4] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[4].xy, shadowCoord.z));
    attenuation += fetchesWeights[5] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[5].xy, shadowCoord.z));
    attenuation += fetchesWeights[6] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[6].xy, shadowCoord.z));
    attenuation += fetchesWeights[7] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[7].xy, shadowCoord.z));
    attenuation += fetchesWeights[8] * SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, real3(fetchesUV[8].xy, shadowCoord.z));
#endif
#else
    // 1-tap hardware comparison
    attenuation = SAMPLE_TEXTURE2D_SHADOW(_ShadowMap, sampler_ShadowMap, shadowCoord.xyz);
#endif

    // Apply shadow strength
    attenuation = LerpWhiteTo(attenuation, _ShadowData.x);

    // Shadow coords that fall out of the light frustum volume must always return attenuation 1.0
    // TODO: We can set shadowmap sampler to clamptoborder when we don't have a shadow atlas and avoid xy coord bounds check
    return (shadowCoord.x <= 0 || shadowCoord.x >= 1 || shadowCoord.y <= 0 || shadowCoord.y >= 1 || shadowCoord.z >= 1) ? 1.0 : attenuation;
}

inline half ComputeCascadeIndex(float3 positionWS)
{
    // TODO: profile if there's a performance improvement if we avoid indexing here
    float3 fromCenter0 = positionWS.xyz - _DirShadowSplitSpheres[0].xyz;
    float3 fromCenter1 = positionWS.xyz - _DirShadowSplitSpheres[1].xyz;
    float3 fromCenter2 = positionWS.xyz - _DirShadowSplitSpheres[2].xyz;
    float3 fromCenter3 = positionWS.xyz - _DirShadowSplitSpheres[3].xyz;
    float4 distances2 = float4(dot(fromCenter0, fromCenter0), dot(fromCenter1, fromCenter1), dot(fromCenter2, fromCenter2), dot(fromCenter3, fromCenter3));

    half4 weights = half4(distances2 < _DirShadowSplitSphereRadii);
    weights.yzw = saturate(weights.yzw - weights.xyz);

    return 4 - dot(weights, half4(4, 3, 2, 1));
}

half4 ComputeShadowCoord(float3 positionWS)
{
#ifdef _SHADOWS_CASCADE
    half cascadeIndex = ComputeCascadeIndex(positionWS);
    return mul(_WorldToShadow[cascadeIndex], float4(positionWS, 1.0));
#endif

    return mul(_WorldToShadow[0], float4(positionWS, 1.0));
}

half GetShadowStrength()
{
    return _ShadowData.x;
}

half RealtimeShadowAttenuation(float3 positionWS)
{
#if !defined(_SHADOWS_ENABLED)
    return 1.0;
#endif

    half4 shadowCoord = ComputeShadowCoord(positionWS);
    return SampleShadowmap(shadowCoord);
}

half RealtimeShadowAttenuation(float3 positionWS, half4 shadowCoord)
{
#if !defined(_SHADOWS_ENABLED)
    return 1.0;
#endif

#ifdef _SHADOWS_CASCADE
    shadowCoord = ComputeShadowCoord(positionWS);
#endif

    return SampleShadowmap(shadowCoord);
}

#endif
