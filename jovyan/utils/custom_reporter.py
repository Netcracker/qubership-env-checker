class Value:
    fields = None

    def __str__(self):
        return str(self.__dict__)

    def __init__(self, *args):
        if self.__class__.fields is None:
            self.__class__.fields = list(args)
        self.__dict__["checks"] = {}
        for field in self.__class__.fields:
            self.__dict__[field] = None

    def create_object(self, **kwargs):
        new_obj = Value(self.__class__.fields)
        for field in self.__class__.fields:
            if field in kwargs:
                new_obj.__dict__[field] = kwargs[field]
        return new_obj

    def get_key(self):
        key_val = hash(
            tuple((key, value) for key, value in self.__dict__.items() if
                  key != "checks")
        )
        return key_val


class Report:
    def __init__(self, *args, report_name="report"):
        self.value_list = {}
        self.value_fields = Value(*args)

        if report_name == "" or report_name is None:
            report_name = "report"
        self.report_name = report_name
        self.isExceptionOccured = False

    def append(self, name, value, **kwargs):
        new_value = self.value_fields.create_object(**kwargs)
        key = new_value.get_key()
        if key not in self.value_list:
            self.value_list[key] = new_value.__dict__
        self.value_list[key]['checks'][name] = value

    def dict(self):
        return {'name': self.report_name,
                'values': list(self.value_list.values()),
                'isExceptionOccured': self.isExceptionOccured}

    def getExceptionStatus(self):
        return self.isExceptionOccured

    def setExceptionStatus(self):
        self.isExceptionOccured = True

    def __iter__(self):
        return iter(self.value_list.values())
