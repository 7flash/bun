#pragma once

#include "root.h"
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/VM.h>

#include "headers-handwritten.h"
#include "BunClientData.h"
#include <JavaScriptCore/CallFrame.h>
#include "node_api.h"
#include <JavaScriptCore/JSWeakValue.h>
#include "JSFFIFunction.h"
#include "ZigGlobalObject.h"
#include "napi_handle_scope.h"

namespace JSC {
class JSGlobalObject;
class JSSourceCode;
}

namespace Napi {
JSC::SourceCode generateSourceCode(WTF::String keyString, JSC::VM& vm, JSC::JSObject* object, JSC::JSGlobalObject* globalObject);
}

struct napi_env__ {
public:
    napi_env__(Zig::GlobalObject* globalObject, const napi_module& napiModule)
        : m_globalObject(globalObject)
        , m_napiModule(napiModule)
    {
    }

    inline Zig::GlobalObject* globalObject() const { return m_globalObject; }
    inline const napi_module& napiModule() const { return m_napiModule; }

    void cleanup()
    {
        if (m_instanceDataFinalizer) {
            m_instanceDataFinalizer(this, m_instanceData, m_instanceDataFinalizerHint);
        }
    }

    void setInstanceData(void* data, napi_finalize finalizer, void* hint)
    {
        m_instanceData = data;
        m_instanceDataFinalizer = finalizer;
        m_instanceDataFinalizerHint = hint;
    }

    inline void* getInstanceData() const
    {
        return m_instanceData;
    }

    napi_status setLastError(napi_status status)
    {
        m_extendedErrorInfo.error_code = status;
        return status;
    }

    // This function is not const because it modifies the extended error info by setting the error
    // message
    const napi_extended_error_info& getLastErrorInfo()
    {
        constexpr napi_status last_status = napi_would_deadlock;

        constexpr const char* error_messages[] = {
            nullptr, // napi_ok
            "Invalid argument",
            "An object was expected",
            "A string was expected",
            "A string or symbol was expected",
            "A function was expected",
            "A number was expected",
            "A boolean was expected",
            "An array was expected",
            "Unknown failure",
            "An exception is pending",
            "The async work item was cancelled",
            "napi_escape_handle already called on scope",
            "Invalid handle scope usage",
            "Invalid callback scope usage",
            "Thread-safe function queue is full",
            "Thread-safe function handle is closing",
            "A bigint was expected",
            "A date was expected",
            "An arraybuffer was expected",
            "A detachable arraybuffer was expected",
            "Main thread would deadlock",
        };

        static_assert(std::size(error_messages) == last_status + 1,
            "error_messages array does not cover all status codes");

        napi_status status = m_extendedErrorInfo.error_code;
        if (status >= 0 && status <= last_status) {
            m_extendedErrorInfo.error_message = error_messages[status];
        } else {
            m_extendedErrorInfo.error_message = nullptr;
        }

        return m_extendedErrorInfo;
    }

private:
    Zig::GlobalObject* m_globalObject = nullptr;
    napi_module m_napiModule;

    void* m_instanceData = nullptr;
    napi_finalize m_instanceDataFinalizer = nullptr;
    void* m_instanceDataFinalizerHint = nullptr;
    napi_extended_error_info m_extendedErrorInfo = {
        .error_message = "",
        // Not currently used by Bun -- always nullptr
        .engine_reserved = nullptr,
        // Not currently used by Bun -- always zero
        .engine_error_code = 0,
        .error_code = napi_ok,
    };
};

namespace Zig {

using namespace JSC;

static inline JSValue toJS(napi_value val)
{
    return JSC::JSValue::decode(reinterpret_cast<JSC::EncodedJSValue>(val));
}

static inline napi_value toNapi(JSC::JSValue val, Zig::GlobalObject* globalObject)
{
    if (val.isCell()) {
        if (auto* scope = globalObject->m_currentNapiHandleScopeImpl.get()) {
            scope->append(val);
        }
    }
    return reinterpret_cast<napi_value>(JSC::JSValue::encode(val));
}

class NapiFinalizer {
public:
    void* finalize_hint = nullptr;
    napi_finalize finalize_cb;

    void call(napi_env env, void* data);
};

// This is essentially JSC::JSWeakValue, except with a JSCell* instead of a
// JSObject*. Sometimes, a napi embedder might want to store a JSC::Exception, a
// JSC::HeapBigInt, JSC::Symbol, etc inside of a NapiRef. So we can't limit it
// to just JSObject*. It has to be JSCell*. It's not clear that we benefit from
// not simply making this JSC::Unknown.
class NapiWeakValue {
public:
    NapiWeakValue() = default;
    ~NapiWeakValue();

    void clear();
    bool isClear() const;

    bool isSet() const { return m_tag != WeakTypeTag::NotSet; }
    bool isPrimitive() const { return m_tag == WeakTypeTag::Primitive; }
    bool isCell() const { return m_tag == WeakTypeTag::Cell; }
    bool isString() const { return m_tag == WeakTypeTag::String; }

    void setPrimitive(JSValue);
    void setCell(JSCell*, WeakHandleOwner&, void* context);
    void setString(JSString*, WeakHandleOwner&, void* context);
    void set(JSValue, WeakHandleOwner&, void* context);

    JSValue get() const
    {
        switch (m_tag) {
        case WeakTypeTag::Primitive:
            return m_value.primitive;
        case WeakTypeTag::Cell:
            return JSC::JSValue(m_value.cell.get());
        case WeakTypeTag::String:
            return JSC::JSValue(m_value.string.get());
        default:
            return JSC::JSValue();
        }
    }

    JSCell* cell() const
    {
        ASSERT(isCell());
        return m_value.cell.get();
    }

    JSValue primitive() const
    {
        ASSERT(isPrimitive());
        return m_value.primitive;
    }

    JSString* string() const
    {
        ASSERT(isString());
        return m_value.string.get();
    }

private:
    enum class WeakTypeTag { NotSet,
        Primitive,
        Cell,
        String };

    WeakTypeTag m_tag { WeakTypeTag::NotSet };

    union WeakValueUnion {
        WeakValueUnion()
            : primitive(JSValue())
        {
        }

        ~WeakValueUnion()
        {
            ASSERT(!primitive);
        }

        JSValue primitive;
        JSC::Weak<JSCell> cell;
        JSC::Weak<JSString> string;
    } m_value;
};

class NapiRef {
    WTF_MAKE_ISO_ALLOCATED(NapiRef);

public:
    void ref();
    void unref();
    void clear();

    NapiRef(napi_env env, uint32_t count)
        : env(env)
        , globalObject(JSC::Weak<JSC::JSGlobalObject>(env->globalObject()))
        , refCount(count)
    {
    }

    JSC::JSValue value() const
    {
        if (refCount == 0) {
            return weakValueRef.get();
        }

        return strongRef.get();
    }

    ~NapiRef()
    {
        strongRef.clear();
        // The weak ref can lead to calling the destructor
        // so we must first clear the weak ref before we call the finalizer
        weakValueRef.clear();
    }

    napi_env env = nullptr;
    JSC::Weak<JSC::JSGlobalObject> globalObject;
    NapiWeakValue weakValueRef;
    JSC::Strong<JSC::Unknown> strongRef;
    NapiFinalizer finalizer;
    void* data = nullptr;
    uint32_t refCount = 0;
};

static inline napi_ref toNapi(NapiRef* val)
{
    return reinterpret_cast<napi_ref>(val);
}

class NapiClass final : public JSC::JSFunction {
public:
    using Base = JSFunction;

    static constexpr unsigned StructureFlags = Base::StructureFlags;
    static constexpr bool needsDestruction = false;
    static void destroy(JSCell* cell)
    {
        static_cast<NapiClass*>(cell)->NapiClass::~NapiClass();
    }

    template<typename, SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<NapiClass, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForNapiClass.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForNapiClass = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForNapiClass.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForNapiClass = std::forward<decltype(space)>(space); });
    }

    DECLARE_EXPORT_INFO;

    JS_EXPORT_PRIVATE static NapiClass* create(VM&, napi_env, const char* utf8name,
        size_t length,
        napi_callback constructor,
        void* data,
        size_t property_count,
        const napi_property_descriptor* properties);

    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        ASSERT(globalObject);
        return Structure::create(vm, globalObject, prototype, TypeInfo(JSFunctionType, StructureFlags), info());
    }

    napi_callback constructor()
    {
        return m_constructor;
    }

    void* dataPtr = nullptr;
    napi_callback m_constructor = nullptr;
    NapiRef* napiRef = nullptr;
    napi_env m_env = nullptr;

    inline napi_env env() const { return m_env; }

private:
    NapiClass(VM& vm, NativeExecutable* executable, napi_env env, Structure* structure)
        : Base(vm, executable, env->globalObject(), structure)
        , m_env(env)
    {
    }
    void finishCreation(VM&, NativeExecutable*, unsigned length, const String& name, napi_callback constructor,
        void* data,
        size_t property_count,
        const napi_property_descriptor* properties);

    DECLARE_VISIT_CHILDREN;
};

class NapiPrototype : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;

    static constexpr unsigned StructureFlags = Base::StructureFlags;
    static constexpr bool needsDestruction = true;

    template<typename CellType, SubspaceAccess>
    static CompleteSubspace* subspaceFor(VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    DECLARE_INFO;

    static NapiPrototype* create(VM& vm, Structure* structure)
    {
        NapiPrototype* footprint = new (NotNull, allocateCell<NapiPrototype>(vm)) NapiPrototype(vm, structure);
        footprint->finishCreation(vm);
        return footprint;
    }

    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        ASSERT(globalObject);
        return Structure::create(vm, globalObject, prototype, TypeInfo(ObjectType, StructureFlags), info());
    }

    NapiPrototype* subclass(JSC::JSGlobalObject* globalObject, JSC::JSObject* newTarget)
    {
        auto& vm = this->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* targetFunction = jsCast<JSFunction*>(newTarget);
        FunctionRareData* rareData = targetFunction->ensureRareData(vm);
        auto* prototype = newTarget->get(globalObject, vm.propertyNames->prototype).getObject();
        RETURN_IF_EXCEPTION(scope, nullptr);

        // This must be kept in-sync with InternalFunction::createSubclassStructure
        Structure* structure = rareData->internalFunctionAllocationStructure();
        if (UNLIKELY(!(structure && structure->classInfoForCells() == this->structure()->classInfoForCells() && structure->globalObject() == globalObject))) {
            structure = rareData->createInternalFunctionAllocationStructureFromBase(vm, globalObject, prototype, this->structure());
        }

        RETURN_IF_EXCEPTION(scope, nullptr);
        NapiPrototype* footprint = new (NotNull, allocateCell<NapiPrototype>(vm)) NapiPrototype(vm, structure);
        footprint->finishCreation(vm);
        RELEASE_AND_RETURN(scope, footprint);
    }

    NapiRef* napiRef = nullptr;

private:
    NapiPrototype(VM& vm, Structure* structure)
        : Base(vm, structure)
    {
    }
};

static inline NapiRef* toJS(napi_ref val)
{
    return reinterpret_cast<NapiRef*>(val);
}

Structure* createNAPIFunctionStructure(VM& vm, JSC::JSGlobalObject* globalObject);

}
