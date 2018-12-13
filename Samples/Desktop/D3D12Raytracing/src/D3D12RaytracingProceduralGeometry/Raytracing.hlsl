//********************************************************* 
// 
// Copyright (c) Microsoft. All rights reserved. 
// This code is licensed under the MIT License (MIT). 
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF 
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY 
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR 
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT. 
// 
//********************************************************* 

#ifndef RAYTRACING_HLSL 
#define RAYTRACING_HLSL 

#define HLSL 
#include "RaytracingHlslCompat.h" 
#include "ProceduralPrimitivesLibrary.hlsli" 
#include "RaytracingShaderHelper.hlsli" 

#define WINDOW_WIDTH 1280 
#define WINDOWS_HEIGHT 720 

//*************************************************************************** 
//*****------ Shader resources bound via root signatures -------************* 
//*************************************************************************** 

// Scene wide resources. 
//  g_* - bound via a global root signature. 
//  l_* - bound via a local root signature. 
RaytracingAccelerationStructure g_scene : register(t0, space0);
RWTexture2D<float4> g_renderTarget : register(u0);
ConstantBuffer<SceneConstantBuffer> g_sceneCB : register(b0);

// Triangle resources 
ByteAddressBuffer g_indices : register(t1, space0);
StructuredBuffer<Vertex> g_vertices : register(t2, space0);

// Procedural geometry resources 
StructuredBuffer<PrimitiveInstancePerFrameBuffer> g_AABBPrimitiveAttributes : register(t3, space0);
ConstantBuffer<PrimitiveConstantBuffer> l_materialCB : register(b1);
ConstantBuffer<PrimitiveInstanceConstantBuffer> l_aabbCB: register(b2);

//*************************************************************************** 
//*****------ TraceRay wrappers for radiance and shadow rays. -------******** 
//*************************************************************************** 

// Trace a radiance ray into the scene and returns a shaded color. 
float4 TraceRadianceRay(in Ray ray, in UINT currentRayRecursionDepth)
{
	if (currentRayRecursionDepth >= MAX_RAY_RECURSION_DEPTH)
	{
		return float4(0, 0, 0, 0);
	}

	// Set the ray's extents. 
	RayDesc rayDesc;
	rayDesc.Origin = ray.origin;
	rayDesc.Direction = ray.direction;
	// Set TMin to a zero value to avoid aliasing artifacts along contact areas. 
	// Note: make sure to enable face culling so as to avoid surface face fighting. 
	rayDesc.TMin = 0;
	rayDesc.TMax = 10000;
	RayPayload rayPayload = { float4(0, 0, 0, 0), currentRayRecursionDepth + 1 };
	TraceRay(g_scene,
		RAY_FLAG_CULL_BACK_FACING_TRIANGLES,
		TraceRayParameters::InstanceMask,
		TraceRayParameters::HitGroup::Offset[RayType::Radiance],
		TraceRayParameters::HitGroup::GeometryStride,
		TraceRayParameters::MissShader::Offset[RayType::Radiance],
		rayDesc, rayPayload);

	return rayPayload.color;
}

//*************************************************************************** 
//********************------ Ray gen shader.. -------************************ 
//*************************************************************************** 

[shader("raygeneration")]
void MyRaygenShader()
{
	// Generate a ray for a camera pixel corresponding to an index from the dispatched 2D grid. 
	Ray ray = GenerateCameraRay(DispatchRaysIndex().xy, g_sceneCB.cameraPosition.xyz, g_sceneCB.projectionToWorld);

	// Cast a ray into the scene and retrieve a shaded color. 
	UINT currentRecursionDepth = 0;
	float4 color = TraceRadianceRay(ray, currentRecursionDepth);

	// Write the raytraced color to the output texture. 
	g_renderTarget[DispatchRaysIndex().xy] = color;
}

//*************************************************************************** 
//******************------ Closest hit shaders -------*********************** 
//*************************************************************************** 

[shader("closesthit")]
void MyClosestHitShader_Triangle(inout RayPayload rayPayload, in BuiltInTriangleIntersectionAttributes attr)
{
	// Get the base index of the triangle's first 16 bit index. 
	uint indexSizeInBytes = 2;
	uint indicesPerTriangle = 3;
	uint triangleIndexStride = indicesPerTriangle * indexSizeInBytes;
	uint baseIndex = PrimitiveIndex() * triangleIndexStride;

	// Load up three 16 bit indices for the triangle. 
	const uint3 indices = Load3x16BitIndices(baseIndex, g_indices);

	// Retrieve corresponding vertex normals for the triangle vertices. 
	float3 triangleNormal = g_vertices[indices[0]].normal;

	// Trace a shadow ray. 
	float3 hitPosition = HitWorldPosition();
	RayDesc shadowRay;
	shadowRay.Origin = hitPosition;
	shadowRay.TMin = 0.01;
	shadowRay.TMax = 10000;

	float t = g_sceneCB.elapsedTime * hitPosition.xy;

	ShadowRayPayload shadowPayload = { 0.5 };

	// Dynamic light 
	{
		float3 offset = float3(Random(t), Random(t * 2.1489375), Random(t * 3.14796253)) - 0.5;
		offset *= 1.0;

		shadowRay.Direction = normalize(g_sceneCB.lightPosition.xyz - hitPosition + offset);

		TraceRay(g_scene,
			RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH
			| RAY_FLAG_FORCE_OPAQUE             // ~skip any hit shaders 
			| RAY_FLAG_SKIP_CLOSEST_HIT_SHADER, // ~skip closest hit shaders, 
			TraceRayParameters::InstanceMask,
			TraceRayParameters::HitGroup::Offset[RayType::Shadow],
			TraceRayParameters::HitGroup::GeometryStride,
			TraceRayParameters::MissShader::Offset[RayType::Shadow],
			shadowRay, shadowPayload);
	}

	// Static light 
	{
		float3 offset = float3(Random(t), Random(t * 2.1489375), Random(t * 3.14796253)) - 0.5;
		offset *= 1.0;

		shadowRay.Direction = normalize(float3(8.05484772, 18.0000000, 18.3062706) - hitPosition + offset);

		TraceRay(g_scene,
			RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH
			| RAY_FLAG_FORCE_OPAQUE             // ~skip any hit shaders 
			| RAY_FLAG_SKIP_CLOSEST_HIT_SHADER, // ~skip closest hit shaders, 
			TraceRayParameters::InstanceMask,
			TraceRayParameters::HitGroup::Offset[RayType::Shadow],
			TraceRayParameters::HitGroup::GeometryStride,
			TraceRayParameters::MissShader::Offset[RayType::Shadow],
			shadowRay, shadowPayload);
	}

	rayPayload.color = float4(triangleNormal.xyz, 1.0) * shadowPayload.factor;
}

[shader("closesthit")]
void MyClosestHitShader_AABB(inout RayPayload rayPayload, in ProceduralPrimitiveAttributes attr)
{
	rayPayload.color = float4(0.0, 0.0, 0.0, 1.0);
}

//*************************************************************************** 
//**********************------ Miss shaders -------************************** 
//*************************************************************************** 

[shader("miss")]
void MyMissShader(inout RayPayload rayPayload)
{
	float4 backgroundColor = float4(BackgroundColor);
	rayPayload.color = float4(0, 0, 0, 1);
}

[shader("miss")]
void MyMissShader_ShadowRay(inout ShadowRayPayload rayPayload)
{
	rayPayload.factor += rayPayload.factor * 0.5;
}

//*************************************************************************** 
//*****************------ Intersection shaders-------************************ 
//*************************************************************************** 

// Get ray in AABB's local space. 
Ray GetRayInAABBPrimitiveLocalSpace()
{
	PrimitiveInstancePerFrameBuffer attr = g_AABBPrimitiveAttributes[l_aabbCB.instanceIndex];

	// Retrieve a ray origin position and direction in bottom level AS space  
	// and transform them into the AABB primitive's local space. 
	Ray ray;
	ray.origin = mul(float4(ObjectRayOrigin(), 1), attr.bottomLevelASToLocalSpace).xyz;
	ray.direction = mul(ObjectRayDirection(), (float3x3) attr.bottomLevelASToLocalSpace);
	return ray;
}

[shader("intersection")]
void MyIntersectionShader_AnalyticPrimitive()
{

}

[shader("intersection")]
void MyIntersectionShader_VolumetricPrimitive()
{

}

[shader("intersection")]
void MyIntersectionShader_SignedDistancePrimitive()
{

}

#endif // RAYTRACING_HLSL
