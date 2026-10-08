#pragma once
#include <aquamarine/input/Input.hpp>
#include <string>
namespace Aquamarine {
    class CAnlandPointer : public IPointer {
      public:
        const std::string& getName() override { return m_name; }
      private:
        std::string m_name = "anland-pointer";
    };
    class CAnlandKeyboard : public IKeyboard {
      public:
        const std::string& getName() override { return m_name; }
      private:
        std::string m_name = "anland-keyboard";
    };
    class CAnlandTouch : public ITouch {
      public:
        const std::string& getName() override { return m_name; }
      private:
        std::string m_name = "anland-touch";
    };

}
